-- Hololoco, part 13: how far a player can see, and how much their bag holds.
--
--   sight_m    drops (and items left on the map) show up within this many metres of
--              the player. 300 m to start; add-ons can raise it later. The app's
--              pulsing hexagon shows it. The server enforces it, so a modified app
--              can't see farther.
--   bag_slots  how many items a player can hold at once (status 'held'). 10 to start;
--              add-ons can add slots later. Capturing, picking up and trading check it.

alter table public.player_stats
  add column sight_m integer not null default 300 check (sight_m between 50 and 5000),
  add column bag_slots smallint not null default 10 check (bag_slots between 1 and 500);

-- Someone's sight and bag size, before they have a stats row.
create function private.player_limits(p_user uuid, out sight_m integer, out bag_slots integer)
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((select s.sight_m from public.player_stats s where s.user_id = p_user), 300),
         coalesce((select s.bag_slots from public.player_stats s where s.user_id = p_user), 10);
$$;

create function private.bag_used(p_user uuid)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select count(*)::integer from public.inventory i where i.owner_id = p_user and i.status = 'held';
$$;

revoke execute on function private.player_limits(uuid) from public, anon, authenticated;
revoke execute on function private.bag_used(uuid) from public, anon, authenticated;

create or replace function public.player_json(p_user uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'handle', p.handle,
    'name', p.display_name,
    'xp', coalesce(s.xp, 0),
    'points', coalesce(s.points, 0),
    'level', public.level_for(coalesce(s.xp, 0)),
    'levelXp', public.xp_for_level(public.level_for(coalesce(s.xp, 0))),
    'nextLevelXp', public.xp_for_level(public.level_for(coalesce(s.xp, 0)) + 1),
    'captures', coalesce(s.captures, 0),
    'sightMetres', coalesce(s.sight_m, 300),
    'bagSlots', coalesce(s.bag_slots, 10),
    'bagUsed', private.bag_used(p.id),
    'questsDone', (select count(*) from public.quest_progress g where g.user_id = p.id and g.completed_at is not null),
    'eventsDone', (select count(*) from public.event_progress g where g.user_id = p.id and g.completed_at is not null))
  from public.profiles p
  left join public.player_stats s on s.user_id = p.id
  where p.id = p_user;
$$;

-- What's around: never farther than the player's sight (300 m for visitors).
create or replace function public.app_nearby(lat double precision, lng double precision, radius_m integer default 500)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
  v_here extensions.geography;
  v_radius integer := least(greatest(coalesce(radius_m, 500), 50), (private.player_limits(me)).sight_m);
begin
  if app_nearby.lat is null or app_nearby.lng is null
     or app_nearby.lat not between -85 and 85 or app_nearby.lng not between -180 and 180 then
    raise exception 'bad_location' using errcode = 'P0001';
  end if;
  v_here := private.point(app_nearby.lat, app_nearby.lng);

  return jsonb_build_object(
    'radius', v_radius,
    'drops', coalesce((
      select jsonb_agg(x.j order by x.dist)
      from (
        select public.drop_to_json(d) || jsonb_build_object(
                 'distance', round(m.dist::numeric, 1),
                 'captured', me is not null and exists (
                   select 1 from public.inventory i where i.drop_id = d.id and i.captured_by = me and i.source = 'capture'),
                 'mine', d.owner_id = me,
                 'quest', (select jsonb_build_object('id', q.id, 'name', q.name, 'position', s.position, 'stageCount', q.stage_count)
                           from public.quest_stages s join public.quests q on q.id = s.quest_id
                           where s.drop_id = d.id and q.status = 'active' limit 1),
                 'events', (select jsonb_agg(jsonb_build_object('id', e.id, 'title', e.title, 'position', es.position))
                            from public.event_stops es join public.events e on e.id = es.event_id
                            where es.drop_id = d.id and private.event_live(e))) as j,
               m.dist
        from public.drops d
        cross join lateral (select extensions.st_distance(d.geom::extensions.geography, v_here) as dist) m
        where extensions.st_dwithin(d.geom::extensions.geography, v_here, v_radius)
          and public.drop_on_map(d)
          and private.drop_shown(d.id, me)
        order by m.dist
        limit 200) x), '[]'::jsonb),
    'items', coalesce((
      select jsonb_agg(x.j order by x.dist)
      from (
        select jsonb_build_object(
                 'id', i.id, 'kind', i.kind, 'rarity', i.rarity, 'title', i.snapshot ->> 'title', 'drop', i.snapshot,
                 'placement', jsonb_build_object('lat', l.lat, 'lng', l.lng),
                 'distance', round(m.dist::numeric, 1), 'droppedAt', l.dropped_at, 'mine', l.dropped_by = me) as j,
               m.dist
        from public.loose_items l
        join public.inventory i on i.id = l.item_id
        cross join lateral (select extensions.st_distance(l.geom::extensions.geography, v_here) as dist) m
        where extensions.st_dwithin(l.geom::extensions.geography, v_here, v_radius)
          and l.expires_at > now() and i.status = 'dropped'
        order by m.dist
        limit 100) x), '[]'::jsonb),
    'quests', coalesce((
      select jsonb_agg(public.quest_to_json(q) || jsonb_build_object(
               'progress', (select jsonb_build_object('stage', g.stage, 'completedAt', g.completed_at)
                            from public.quest_progress g where g.quest_id = q.id and g.user_id = me)))
      from public.quests q
      where q.status = 'active'
        and exists (select 1 from public.quest_stages s join public.drops d on d.id = s.drop_id
                    where s.quest_id = q.id and s.position = 1
                      and extensions.st_dwithin(d.geom::extensions.geography, v_here, v_radius))), '[]'::jsonb),
    'events', coalesce((
      select jsonb_agg(public.event_to_json(e, me))
      from public.events e
      where private.event_live(e)
        and exists (select 1 from public.event_stops s join public.drops d on d.id = s.drop_id
                    where s.event_id = e.id
                      and extensions.st_dwithin(d.geom::extensions.geography, v_here, v_radius))), '[]'::jsonb),
    'player', case when me is not null then public.player_json(me) end);
end;
$$;

-- Bag space is checked before anything new goes in. The capture function is long,
-- so instead of repeating it, a trigger on the inventory refuses an item that would
-- overfill its owner's bag: a capture, a pick-up, an event reward or a trade.
create function public.inventory_bag_check()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- The database's own jobs (an item nobody picked up going back to whoever left it)
  -- and trades, which check both bags first, aren't stopped here.
  if auth.uid() is null or coalesce(current_setting('hololoco.bagcheck', true), '') = 'off' or new.status <> 'held' then
    return new;
  end if;
  if tg_op = 'UPDATE' and old.status = 'held' and old.owner_id = new.owner_id then
    return new;
  end if;
  if private.bag_used(new.owner_id) >= (private.player_limits(new.owner_id)).bag_slots then
    raise exception 'bag_full' using errcode = 'P0001';
  end if;
  return new;
end;
$$;

revoke execute on function public.inventory_bag_check() from public, anon, authenticated;

create trigger inventory_bag_check
  before insert or update of owner_id, status on public.inventory
  for each row execute function public.inventory_bag_check();

-- Trades: both bags must have room once the items swap.
create or replace function public.answer_trade(trade_id uuid, accept boolean)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
  v_trade public.trades;
  v_ok boolean;
  v_give integer;
  v_get integer;
begin
  select * into v_trade from public.trades t
  where t.id = answer_trade.trade_id and t.to_id = me and t.status = 'open' and t.expires_at > now()
  for update;
  if v_trade.id is null then
    raise exception 'trade_not_found' using errcode = 'P0001';
  end if;

  if not accept then
    update public.trades t set status = 'declined', decided_at = now() where t.id = v_trade.id;
    return jsonb_build_object('id', v_trade.id, 'status', 'declined');
  end if;

  perform 1 from public.inventory i join public.trade_items x on x.item_id = i.id
  where x.trade_id = v_trade.id for update of i;

  select bool_and(i.status = 'held' and i.tradeable
                  and i.owner_id = case x.side when 'give' then v_trade.from_id else v_trade.to_id end)
  into v_ok
  from public.trade_items x join public.inventory i on i.id = x.item_id
  where x.trade_id = v_trade.id;

  if not coalesce(v_ok, false) then
    update public.trades t set status = 'failed', decided_at = now() where t.id = v_trade.id;
    return jsonb_build_object('id', v_trade.id, 'status', 'failed');
  end if;

  select count(*) filter (where x.side = 'give'), count(*) filter (where x.side = 'get')
  into v_give, v_get
  from public.trade_items x where x.trade_id = v_trade.id;
  if private.bag_used(v_trade.to_id) - v_get + v_give > (private.player_limits(v_trade.to_id)).bag_slots then
    raise exception 'bag_full' using errcode = 'P0001';
  end if;
  if private.bag_used(v_trade.from_id) - v_give + v_get > (private.player_limits(v_trade.from_id)).bag_slots then
    raise exception 'their_bag_full' using errcode = 'P0001';
  end if;

  delete from public.redemptions r
  where r.confirmed_at is null and r.item_id in (select x.item_id from public.trade_items x where x.trade_id = v_trade.id);
  perform set_config('hololoco.bagcheck', 'off', true);
  update public.inventory i set
    owner_id = case x.side when 'give' then v_trade.to_id else v_trade.from_id end,
    source = 'trade', for_trade = false, updated_at = now()
  from public.trade_items x
  where x.trade_id = v_trade.id and x.item_id = i.id;
  perform set_config('hololoco.bagcheck', '', true);
  update public.trades t set status = 'accepted', decided_at = now() where t.id = v_trade.id;
  return jsonb_build_object('id', v_trade.id, 'status', 'accepted');
end;
$$;
