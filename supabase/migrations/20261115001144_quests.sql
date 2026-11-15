-- Hololoco, part 7: the quest builder.
--
-- A quest chains offers from different businesses into stages: a common offer
-- first, one or two uncommon ones, and a rare one last. The database builds
-- quests by itself, every 15 minutes, from offers whose businesses opted in:
--   * every stage is live, in stock, and from a different business;
--   * the stages are open together at least 4 hours a week, in one time zone
--     (offers shown one time only, like an event, don't join quests);
--   * each leg is at most a 20-minute walk (1.6 km), stretching to 5 km and then
--     15 km where businesses are farther apart, as in rural areas;
--   * an offer is in one quest at a time.
-- A quest stays as it was built until a stage drops out (paused, sold out, taken
-- down, out of quests, a different rarity, moved too far, or its hours no longer
-- overlap). Then it's retired, and its other offers can join a new one.
--
-- The app reads quests through public_quests_in_bounds and public_quest. Owners
-- see their offer's quest in my_drops; staff see every quest and can build now.

create table public.quests (
  id text primary key default public.new_drop_id(),
  name text not null,
  status text not null default 'active' check (status in ('active', 'retired')),
  stage_count smallint not null check (stage_count between 3 and 4),
  -- The longest leg allowed when it was built: 1600, 5000 or 15000 m.
  max_leg_m integer not null,
  time_zone text not null,
  -- The hours of the week, in time_zone, when every stage is open: bit 0 is
  -- Sunday 00:00 to 01:00, bit 167 is Saturday 23:00 to midnight.
  open_hours bit(168) not null,
  built_at timestamptz not null default now(),
  retired_at timestamptz,
  retired_reason text
);

create index quests_active_idx on public.quests (built_at desc) where status = 'active';

create table public.quest_stages (
  quest_id text not null references public.quests (id) on delete cascade,
  position smallint not null check (position between 1 and 4),
  drop_id text not null references public.drops (id) on delete cascade,
  -- The rarity this stage needs. If the offer's rarity changes, the quest retires.
  rarity text not null check (rarity in ('common', 'uncommon', 'rare')),
  primary key (quest_id, position)
);

create index quest_stages_drop_idx on public.quest_stages (drop_id);

-- No policies and no grants: quests are read and built only through the functions below.
alter table public.quests enable row level security;
alter table public.quest_stages enable row level security;
revoke all on table public.quests from anon, authenticated;
revoke all on table public.quest_stages from anon, authenticated;

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- The hours of the week a drop is on the map, in its own time zone. An hour
-- counts when the drop is on at its start. One-time drops have no weekly hours.
create function public.drop_week_hours(d public.drops)
returns bit(168)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_mask bit(168) := repeat('0', 168)::bit(168);
  v_block record;
  v_day smallint;
  v_hour integer;
begin
  if d.timing = 'always' then
    return repeat('1', 168)::bit(168);
  elsif d.timing <> 'weekly' then
    return v_mask;
  end if;
  for v_block in select b.days, b.start_time, b.end_time from public.schedule_blocks b where b.drop_id = d.id loop
    for v_hour in 0..23 loop
      if make_time(v_hour, 0, 0) >= v_block.start_time and make_time(v_hour, 0, 0) < v_block.end_time then
        foreach v_day in array v_block.days loop
          v_mask := set_bit(v_mask, v_day * 24 + v_hour, 1);
        end loop;
      end if;
    end loop;
  end loop;
  return v_mask;
end;
$$;

revoke execute on function public.drop_week_hours(public.drops) from public, anon, authenticated;

-- Why an offer can't be (or stay) a stage that needs this rarity, or null if it can.
-- The words follow "Stage 2 …".
create function private.quest_stage_problem(p_drop text, p_rarity text)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when d.id is null then 'was deleted'
    when d.type <> 'offer' or o.drop_id is null then 'is no longer an offer'
    when not o.in_quests then 'left quests'
    when o.rarity <> p_rarity then 'has a different rarity now'
    when o.claimed >= o.quantity then 'is sold out'
    when d.review <> 'approved' then 'is not live'
    when d.paused then 'is paused'
    when d.audience <> 'everyone' then 'is not public'
    when d.timing = 'once' then 'is shown one time only'
    when p.strikes >= 3 then 'is from a suspended business'
  end
  from (select p_drop as id) x
  left join public.drops d on d.id = x.id
  left join public.offers o on o.drop_id = d.id
  left join public.profiles p on p.id = d.owner_id;
$$;

-- The first reason a quest can't go on, or null if it can.
create function private.quest_problem(p_quest text)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_quest public.quests;
  v_stage record;
  v_drop public.drops;
  v_prev extensions.geography;
  v_mask bit(168) := repeat('1', 168)::bit(168);
  v_problem text;
  v_count integer := 0;
begin
  select * into v_quest from public.quests q where q.id = p_quest;
  for v_stage in select s.position, s.rarity, s.drop_id from public.quest_stages s
                 where s.quest_id = p_quest order by s.position loop
    v_count := v_count + 1;
    v_problem := private.quest_stage_problem(v_stage.drop_id, v_stage.rarity);
    if v_problem is not null then
      return format('Stage %s %s.', v_stage.position, v_problem);
    end if;
    select * into v_drop from public.drops d where d.id = v_stage.drop_id;
    if v_drop.time_zone <> v_quest.time_zone then
      return format('Stage %s is in a different time zone now.', v_stage.position);
    end if;
    if v_prev is not null
       and extensions.st_distance(v_prev, v_drop.geom::extensions.geography) > v_quest.max_leg_m * 1.25 then
      return format('Stage %s moved too far from the one before.', v_stage.position);
    end if;
    v_prev := v_drop.geom::extensions.geography;
    v_mask := v_mask & public.drop_week_hours(v_drop);
  end loop;
  if v_count < v_quest.stage_count then
    return 'A stage was deleted.';
  end if;
  if bit_count(v_mask) < 4 then
    return 'Its stages are no longer open together 4 hours a week.';
  end if;
  return null;
end;
$$;

-- The hours of the week when every stage of a quest is open.
create function private.quest_hours(p_quest text)
returns bit(168)
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(bit_and(public.drop_week_hours(d)), repeat('0', 168)::bit(168))
  from public.quest_stages s join public.drops d on d.id = s.drop_id
  where s.quest_id = p_quest;
$$;

revoke execute on function private.quest_stage_problem(text, text) from public, anon, authenticated;
revoke execute on function private.quest_problem(text) from public, anon, authenticated;
revoke execute on function private.quest_hours(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Building
-- ---------------------------------------------------------------------------

-- Builds as many new quests as it can from offers not in one yet. It starts from
-- each rare offer (the scarcest), finds the nearest uncommon offer, perhaps a
-- second one before that, and the nearest common offer to start from; first
-- within a 20-minute walk for every leg, then 5 km, then 15 km.
create function private.build_quests()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_min_hours constant integer := 4;
  v_tier integer;
  v_rare record;
  v_late record;
  v_early record;
  v_first record;
  v_has_early boolean;
  v_mask bit(168);
  v_owners uuid[];
  v_quest text;
  v_built integer := 0;
begin
  drop table if exists pg_temp.quest_pool;
  create temp table quest_pool as
    select d.id, d.owner_id, o.rarity, d.time_zone, d.created_at,
           d.geom::extensions.geography as geog,
           public.drop_week_hours(d) as hours,
           false as used
    from public.drops d
    join public.offers o on o.drop_id = d.id
    join public.profiles p on p.id = d.owner_id
    where d.type = 'offer' and o.in_quests and o.claimed < o.quantity
      and d.review = 'approved' and not d.paused and d.audience = 'everyone'
      and d.timing in ('always', 'weekly') and p.strikes < 3
      and not exists (select 1 from public.quest_stages s join public.quests q on q.id = s.quest_id
                      where s.drop_id = d.id and q.status = 'active');
  delete from pg_temp.quest_pool where bit_count(hours) < v_min_hours;

  foreach v_tier in array array[1600, 5000, 15000] loop
    for v_rare in select * from pg_temp.quest_pool where rarity = 'rare' and not used order by created_at, id loop
      -- The last uncommon stage: the nearest to the rare one.
      select * into v_late from pg_temp.quest_pool p
      where p.rarity = 'uncommon' and not p.used and p.owner_id <> v_rare.owner_id
        and p.time_zone = v_rare.time_zone
        and extensions.st_dwithin(p.geog, v_rare.geog, v_tier)
        and bit_count(p.hours & v_rare.hours) >= v_min_hours
      order by extensions.st_distance(p.geog, v_rare.geog), p.created_at, p.id
      limit 1;
      continue when not found;

      v_mask := v_rare.hours & v_late.hours;
      v_owners := array[v_rare.owner_id, v_late.owner_id];

      -- Perhaps a second uncommon stage before it, and a common one before that.
      select * into v_early from pg_temp.quest_pool p
      where p.rarity = 'uncommon' and not p.used and p.id <> v_late.id and p.owner_id <> all (v_owners)
        and p.time_zone = v_rare.time_zone
        and extensions.st_dwithin(p.geog, v_late.geog, v_tier)
        and bit_count(p.hours & v_mask) >= v_min_hours
      order by extensions.st_distance(p.geog, v_late.geog), p.created_at, p.id
      limit 1;
      v_has_early := found;

      if v_has_early then
        select * into v_first from pg_temp.quest_pool p
        where p.rarity = 'common' and not p.used and p.owner_id <> all (v_owners || v_early.owner_id)
          and p.time_zone = v_rare.time_zone
          and extensions.st_dwithin(p.geog, v_early.geog, v_tier)
          and bit_count(p.hours & v_mask & v_early.hours) >= v_min_hours
        order by extensions.st_distance(p.geog, v_early.geog), p.created_at, p.id
        limit 1;
        v_has_early := found;
      end if;

      if v_has_early then
        v_mask := v_mask & v_early.hours & v_first.hours;
      else
        -- Three stages: a common offer straight before the uncommon one.
        select * into v_first from pg_temp.quest_pool p
        where p.rarity = 'common' and not p.used and p.owner_id <> all (v_owners)
          and p.time_zone = v_rare.time_zone
          and extensions.st_dwithin(p.geog, v_late.geog, v_tier)
          and bit_count(p.hours & v_mask) >= v_min_hours
        order by extensions.st_distance(p.geog, v_late.geog), p.created_at, p.id
        limit 1;
        continue when not found;
        v_mask := v_mask & v_first.hours;
      end if;

      insert into public.quests (name, stage_count, max_leg_m, time_zone, open_hours)
      values (
        left(
          coalesce((select p.display_name from public.profiles p where p.id = v_first.owner_id), 'Someone')
          || ' to ' ||
          coalesce((select p.display_name from public.profiles p where p.id = v_rare.owner_id), 'someone'),
          90),
        case when v_has_early then 4 else 3 end,
        v_tier, v_rare.time_zone, v_mask)
      returning id into v_quest;

      insert into public.quest_stages (quest_id, position, drop_id, rarity) values (v_quest, 1, v_first.id, 'common');
      if v_has_early then
        insert into public.quest_stages (quest_id, position, drop_id, rarity) values
          (v_quest, 2, v_early.id, 'uncommon'), (v_quest, 3, v_late.id, 'uncommon'), (v_quest, 4, v_rare.id, 'rare');
        update pg_temp.quest_pool set used = true where id in (v_first.id, v_early.id, v_late.id, v_rare.id);
      else
        insert into public.quest_stages (quest_id, position, drop_id, rarity) values
          (v_quest, 2, v_late.id, 'uncommon'), (v_quest, 3, v_rare.id, 'rare');
        update pg_temp.quest_pool set used = true where id in (v_first.id, v_late.id, v_rare.id);
      end if;
      v_built := v_built + 1;
    end loop;
  end loop;

  drop table pg_temp.quest_pool;
  return v_built;
end;
$$;

-- Retires quests that can't go on, keeps the others' hours up to date, and
-- builds new ones. Runs every 15 minutes, and when staff ask.
create function private.refresh_quests()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_quest record;
  v_problem text;
  v_retired integer := 0;
begin
  perform pg_advisory_xact_lock(hashtext('hololoco.quests'));

  for v_quest in select q.id from public.quests q where q.status = 'active' loop
    v_problem := private.quest_problem(v_quest.id);
    if v_problem is not null then
      update public.quests q set status = 'retired', retired_at = now(), retired_reason = v_problem
      where q.id = v_quest.id;
      v_retired := v_retired + 1;
    else
      update public.quests q set open_hours = private.quest_hours(q.id)
      where q.id = v_quest.id and q.open_hours <> private.quest_hours(q.id);
    end if;
  end loop;

  return jsonb_build_object('retired', v_retired, 'built', private.build_quests());
end;
$$;

revoke execute on function private.build_quests() from public, anon, authenticated;
revoke execute on function private.refresh_quests() from public, anon, authenticated;

select cron.schedule('build-quests', '*/15 * * * *', 'select private.refresh_quests()');

-- ---------------------------------------------------------------------------
-- Reading quests
-- ---------------------------------------------------------------------------

-- A quest as the app sees it. A stage whose offer isn't public any more (taken
-- down since the last refresh, say) comes without its drop.
create function public.quest_to_json(q public.quests)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'id', q.id,
    'name', q.name,
    'status', q.status,
    'stageCount', q.stage_count,
    'maxLegMetres', q.max_leg_m,
    'timeZone', q.time_zone,
    'openHours', q.open_hours::text,
    'openNow', q.status = 'active' and not exists (
      select 1 from public.quest_stages s join public.drops d on d.id = s.drop_id
      where s.quest_id = q.id and not public.drop_is_open(d)),
    'builtAt', q.built_at,
    'stages', coalesce((
      select jsonb_agg(jsonb_build_object(
          'position', s.position,
          'rarity', s.rarity,
          'drop', case when d.review = 'approved' and not d.paused
                         and not exists (select 1 from public.profiles p where p.id = d.owner_id and p.strikes >= 3)
                       then public.drop_to_json(d) end)
        order by s.position)
      from public.quest_stages s join public.drops d on d.id = s.drop_id
      where s.quest_id = q.id), '[]'::jsonb));
$$;

revoke execute on function public.quest_to_json(public.quests) from public, anon, authenticated;

-- Active quests with a stage inside the visible map area, newest first.
create function public.public_quests_in_bounds(
  west double precision,
  south double precision,
  east double precision,
  north double precision,
  max_results integer default 100
)
returns setof jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select public.quest_to_json(q)
  from public.quests q
  where q.status = 'active'
    and exists (select 1 from public.quest_stages s join public.drops d on d.id = s.drop_id
                where s.quest_id = q.id
                  and extensions.st_intersects(d.geom, extensions.st_makeenvelope(west, south, east, north, 4326)))
  order by q.built_at desc
  limit least(greatest(max_results, 1), 300);
$$;

-- One quest, active or retired (a player part-way through a retired quest still needs it).
create function public.public_quest(quest_id text)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select public.quest_to_json(q) from public.quests q where q.id = quest_id;
$$;

revoke execute on function public.public_quests_in_bounds(double precision, double precision, double precision, double precision, integer) from public;
revoke execute on function public.public_quest(text) from public;
grant execute on function public.public_quests_in_bounds(double precision, double precision, double precision, double precision, integer) to anon, authenticated;
grant execute on function public.public_quest(text) to anon, authenticated;

-- Owners see which quest each offer is in.
create or replace function public.my_drops()
returns setof jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select public.drop_to_json(d) || jsonb_build_object(
    'hiddenForReport', d.review = 'pending'
      and exists (select 1 from public.reports r where r.drop_id = d.id and r.status = 'open'),
    'assetFiles', public.drop_asset_files(d),
    'check', public.drop_check_json(d, false),
    'quest', (select jsonb_build_object('id', q.id, 'name', q.name, 'position', s.position, 'stageCount', q.stage_count)
              from public.quest_stages s join public.quests q on q.id = s.quest_id
              where s.drop_id = d.id and q.status = 'active'
              limit 1))
  from public.drops d
  where d.owner_id = (select auth.uid())
  order by d.created_at desc;
$$;

-- ---------------------------------------------------------------------------
-- Staff
-- ---------------------------------------------------------------------------

-- Every active quest, and those retired in the last week with why.
create function public.staff_quests()
returns setof jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.is_staff() then
    raise exception 'not_staff' using errcode = 'P0001';
  end if;
  return query
    select public.quest_to_json(q) || jsonb_build_object('retiredAt', q.retired_at, 'retiredReason', q.retired_reason)
    from public.quests q
    where q.status = 'active' or q.retired_at > now() - interval '7 days'
    order by q.status, coalesce(q.retired_at, q.built_at) desc
    limit 300;
end;
$$;

-- Build quests now instead of waiting for the next run.
create function public.rebuild_quests()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_staff() then
    raise exception 'not_staff' using errcode = 'P0001';
  end if;
  return private.refresh_quests();
end;
$$;

revoke execute on function public.staff_quests() from public, anon;
revoke execute on function public.rebuild_quests() from public, anon;
grant execute on function public.staff_quests() to authenticated;
grant execute on function public.rebuild_quests() to authenticated;
