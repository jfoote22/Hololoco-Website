-- Hololoco, part 10: playing. What the Hololoco app (Unity) calls.
--
-- Players walk to drops and capture them through the camera. A capture puts an
-- item in their inventory and earns XP. From the inventory they can:
--   * redeem an offer: the app shows a 6-digit code for 10 minutes and the
--     business types it into the website (confirm_redemption). Only the business
--     can confirm, so a screenshot of a coupon is worth nothing;
--   * trade items with another player, by their handle. Players choose which
--     items others can ask for (set_for_trade), so nobody's inventory, and with
--     it where they've been, is on show;
--   * leave an item on the map for someone else to pick up (it comes back after
--     7 days if nobody does), or discard it. A discarded offer goes back in stock.
-- A business can make an offer untradeable; then it can't be traded or left on the map.
-- The per-person limit counts captures, so a traded offer can be redeemed by its new owner.
--
-- Quests: the first stage is open to everyone; each later stage shows up, and can
-- be captured, only once a player has done the stage before it. Finishing earns a bonus.
-- Rarer offers show up less often: an uncommon one on about 60% of days for a
-- given player, a rare one on about 30% (quest stages and event stops always show).
-- Events (the Events plan): a business links 2 to 20 of its own drops into a hunt
-- (any order) or a trail (in order) for a set time, with XP for each stop and a
-- bonus, points and optionally one of its offers as a reward for finishing.
--
-- Locations come from the phone, so they're checked for sense: within about 40 m
-- of the drop (more with poor GPS accuracy, up to 70 m), at most 100 captures a
-- day, and no faster than 250 km/h between captures.
--
-- Every function returns JSON and raises a short error code the app turns into
-- words; docs/app-api.md lists them.

-- ---------------------------------------------------------------------------
-- Players
-- ---------------------------------------------------------------------------

-- A handle other players can find for trading: 3 to 20 lowercase letters, digits or _.
alter table public.profiles add column handle text unique check (handle is null or handle ~ '^[a-z0-9_]{3,20}$');

create table public.player_stats (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  xp integer not null default 0 check (xp >= 0),
  points integer not null default 0 check (points >= 0),
  captures integer not null default 0,
  -- Where and when the last capture was, for the speed check.
  last_lat double precision,
  last_lng double precision,
  last_capture_at timestamptz,
  updated_at timestamptz not null default now()
);

-- Every XP and point award, with why. Kept as the record.
create table public.xp_log (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles (id) on delete cascade,
  xp integer not null,
  points integer not null default 0,
  reason text not null check (reason in ('capture', 'quest_stage', 'quest_complete', 'event_stop', 'event_complete', 'pick_up')),
  drop_id text,
  quest_id text,
  event_id text,
  created_at timestamptz not null default now()
);

create index xp_log_user_idx on public.xp_log (user_id, created_at desc);

-- Level n needs 100 × (1 + 2 + … + (n − 1)) XP: 100 for level 2, 300 for 3, 600 for 4.
create function public.level_for(xp integer)
returns integer
language sql
immutable
set search_path = ''
as $$
  select floor((1 + sqrt(1 + 8 * greatest(xp, 0) / 100.0)) / 2)::integer;
$$;

create function public.xp_for_level(level integer)
returns integer
language sql
immutable
set search_path = ''
as $$
  select (100 * (level - 1) * level / 2)::integer;
$$;

-- ---------------------------------------------------------------------------
-- The inventory
-- ---------------------------------------------------------------------------

create table public.inventory (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles (id) on delete cascade,
  -- Where it came from. The snapshot keeps what it was if the drop changes or goes.
  drop_id text references public.drops (id) on delete set null,
  business_id uuid references public.profiles (id) on delete set null,
  kind text not null check (kind in ('offer', 'object', 'message')),
  rarity text check (rarity in ('common', 'uncommon', 'rare')),
  tradeable boolean not null default true,
  snapshot jsonb not null,
  status text not null default 'held' check (status in ('held', 'dropped', 'redeemed', 'discarded')),
  -- How the current owner got it.
  source text not null check (source in ('capture', 'trade', 'pick_up', 'reward')),
  -- Who first captured it: per-person limits count these.
  captured_by uuid references public.profiles (id) on delete set null,
  -- Up for trade: other players can see it on this player's shelf and ask for it.
  for_trade boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  redeemed_at timestamptz
);

create index inventory_owner_idx on public.inventory (owner_id, status, created_at desc);
create index inventory_drop_idx on public.inventory (drop_id, captured_by);
create index inventory_business_idx on public.inventory (business_id);
create index inventory_captured_by_idx on public.inventory (captured_by, created_at desc);

-- Items left on the map.
create table public.loose_items (
  item_id uuid primary key references public.inventory (id) on delete cascade,
  dropped_by uuid not null references public.profiles (id) on delete cascade,
  lat double precision not null check (lat between -85 and 85),
  lng double precision not null check (lng between -180 and 180),
  geom extensions.geometry(Point, 4326)
    generated always as (extensions.st_setsrid(extensions.st_makepoint(lng, lat), 4326)) stored,
  dropped_at timestamptz not null default now(),
  expires_at timestamptz not null
);

create index loose_items_geom_idx on public.loose_items using gist (geom);
create index loose_items_dropped_by_idx on public.loose_items (dropped_by);

-- A redemption code: shown by the player, typed in by the business.
create table public.redemptions (
  id bigint generated always as identity primary key,
  item_id uuid not null references public.inventory (id) on delete cascade,
  player_id uuid not null references public.profiles (id) on delete cascade,
  business_id uuid not null references public.profiles (id) on delete cascade,
  code text not null check (code ~ '^[0-9]{6}$'),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  confirmed_at timestamptz
);

create unique index redemptions_code_idx on public.redemptions (business_id, code) where confirmed_at is null;
create index redemptions_item_idx on public.redemptions (item_id);
create index redemptions_player_idx on public.redemptions (player_id);
create index redemptions_business_idx on public.redemptions (business_id, confirmed_at desc);

-- How many of an offer were redeemed. Written only by confirm_redemption.
alter table public.offers add column redeemed integer not null default 0 check (redeemed >= 0);

create table public.trades (
  id uuid primary key default gen_random_uuid(),
  from_id uuid not null references public.profiles (id) on delete cascade,
  to_id uuid not null references public.profiles (id) on delete cascade,
  status text not null default 'open' check (status in ('open', 'accepted', 'declined', 'cancelled', 'expired', 'failed')),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '7 days',
  decided_at timestamptz
);

create index trades_from_idx on public.trades (from_id, created_at desc);
create index trades_to_idx on public.trades (to_id, created_at desc);

create table public.trade_items (
  trade_id uuid not null references public.trades (id) on delete cascade,
  item_id uuid not null references public.inventory (id) on delete cascade,
  -- give: from the player who proposed it; get: from the other player.
  side text not null check (side in ('give', 'get')),
  primary key (trade_id, item_id)
);

create index trade_items_item_idx on public.trade_items (item_id);

-- Quest progress: how many stages a player has done.
create table public.quest_progress (
  quest_id text not null references public.quests (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  stage smallint not null check (stage between 1 and 4),
  started_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  completed_at timestamptz,
  primary key (quest_id, user_id)
);

create index quest_progress_user_idx on public.quest_progress (user_id, updated_at desc);

-- ---------------------------------------------------------------------------
-- Events (the Events plan)
-- ---------------------------------------------------------------------------

create table public.events (
  id text primary key default public.new_drop_id(),
  owner_id uuid not null references public.profiles (id) on delete cascade,
  title text not null check (char_length(btrim(title)) between 1 and 70),
  description text not null default '' check (char_length(description) <= 400),
  -- hunt: find every stop, in any order. trail: in order.
  format text not null check (format in ('hunt', 'trail')),
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  stop_xp integer not null default 25 check (stop_xp between 0 and 100),
  bonus_xp integer not null default 300 check (bonus_xp between 0 and 1000),
  bonus_points integer not null default 50 check (bonus_points between 0 and 500),
  -- One of the business's offers, given to each player who finishes while stock lasts.
  reward_drop_id text references public.drops (id) on delete set null,
  paused boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint event_window check (ends_at > starts_at and ends_at <= starts_at + interval '92 days')
);

create index events_owner_idx on public.events (owner_id, starts_at desc);
create index events_window_idx on public.events (ends_at, starts_at);
create index events_reward_idx on public.events (reward_drop_id);

create table public.event_stops (
  event_id text not null references public.events (id) on delete cascade,
  position smallint not null check (position between 1 and 20),
  drop_id text not null references public.drops (id) on delete cascade,
  primary key (event_id, position),
  unique (event_id, drop_id)
);

create index event_stops_drop_idx on public.event_stops (drop_id);

create table public.event_progress (
  event_id text not null references public.events (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  -- The stops found, in the order found.
  found text[] not null default '{}',
  started_at timestamptz not null default now(),
  completed_at timestamptz,
  primary key (event_id, user_id)
);

create index event_progress_user_idx on public.event_progress (user_id);

-- Nothing here is read or written directly: only through the functions below.
alter table public.player_stats enable row level security;
alter table public.xp_log enable row level security;
alter table public.inventory enable row level security;
alter table public.loose_items enable row level security;
alter table public.redemptions enable row level security;
alter table public.trades enable row level security;
alter table public.trade_items enable row level security;
alter table public.quest_progress enable row level security;
alter table public.events enable row level security;
alter table public.event_stops enable row level security;
alter table public.event_progress enable row level security;
revoke all on table public.player_stats, public.xp_log, public.inventory, public.loose_items, public.redemptions,
  public.trades, public.trade_items, public.quest_progress, public.events, public.event_stops, public.event_progress
  from anon, authenticated;

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

create function private.point(p_lat double precision, p_lng double precision)
returns extensions.geography
language sql
immutable
set search_path = ''
as $$
  select extensions.st_setsrid(extensions.st_makepoint(p_lng, p_lat), 4326)::extensions.geography;
$$;

-- Is an event on now?
create function private.event_live(e public.events)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select not e.paused and now() >= e.starts_at and now() < e.ends_at
    and not exists (select 1 from public.profiles p where p.id = e.owner_id and p.strikes >= 3);
$$;

-- Does a rarer offer show up for this player today? Steady for the whole day.
create function private.rarity_roll(p_drop text, p_rarity text, p_user uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select case p_rarity
    when 'uncommon' then ((hashtext(coalesce(p_user::text, 'guest') || ':' || p_drop || ':' || current_date::text)::bigint % 100) + 100) % 100 < 60
    when 'rare' then ((hashtext(coalesce(p_user::text, 'guest') || ':' || p_drop || ':' || current_date::text)::bigint % 100) + 100) % 100 < 30
    else true
  end;
$$;

-- Does this drop show up for this player? A later quest stage: only once they've
-- done the stage before. An event stop: always, while the event is on. A rarer
-- offer: on some days. Everything else: always.
create function private.drop_shown(p_drop text, p_user uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when exists (select 1 from public.quest_stages s join public.quests q on q.id = s.quest_id
                 where s.drop_id = p_drop and q.status = 'active' and s.position > 1)
      then exists (select 1 from public.quest_stages s
                   join public.quests q on q.id = s.quest_id
                   join public.quest_progress g on g.quest_id = q.id and g.user_id = p_user
                   where s.drop_id = p_drop and q.status = 'active' and g.stage >= s.position - 1)
    when exists (select 1 from public.event_stops es join public.events e on e.id = es.event_id
                 where es.drop_id = p_drop and private.event_live(e))
      then true
    else coalesce((select private.rarity_roll(p_drop, o.rarity, p_user)
                   from public.offers o join public.drops d on d.id = o.drop_id
                   where o.drop_id = p_drop and d.type = 'offer'), true)
  end;
$$;

-- What a drop looked like, kept with an item.
create function private.drop_snapshot(d public.drops)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select public.drop_to_json(d) - 'review' - 'reviewReason' - 'paused' - 'openNow' - 'audience';
$$;

create function private.award(p_user uuid, p_xp integer, p_points integer, p_reason text,
                              p_drop text default null, p_quest text default null, p_event text default null)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.xp_log (user_id, xp, points, reason, drop_id, quest_id, event_id)
  select p_user, p_xp, p_points, p_reason, p_drop, p_quest, p_event
  where p_xp > 0 or p_points > 0;
  update public.player_stats s set xp = s.xp + p_xp, points = s.points + p_points, updated_at = now()
  where s.user_id = p_user and (p_xp > 0 or p_points > 0);
$$;

-- XP for capturing a drop.
create function private.capture_xp(p_type text, p_rarity text)
returns integer
language sql
immutable
set search_path = ''
as $$
  select case
    when p_type = 'message' then 5
    when p_type = 'object' then 10
    when p_rarity = 'rare' then 150
    when p_rarity = 'uncommon' then 50
    else 20
  end;
$$;

-- Changes an offer's stock as one of the database's own writes.
create function private.change_stock(p_drop text, p_change integer)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_done boolean;
begin
  if p_drop is null then
    return false;
  end if;
  perform set_config('hololoco.system', 'on', true);
  update public.offers o set claimed = greatest(o.claimed + p_change, 0)
  where o.drop_id = p_drop and (p_change <= 0 or o.claimed + p_change <= o.quantity);
  v_done := found;
  perform set_config('hololoco.system', '', true);
  return v_done;
end;
$$;

-- An item as the app sees it.
create function public.item_to_json(i public.inventory)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'id', i.id,
    'kind', i.kind,
    'rarity', i.rarity,
    'title', i.snapshot ->> 'title',
    'status', i.status,
    'source', i.source,
    'tradeable', i.tradeable,
    'forTrade', i.for_trade,
    'dropId', i.drop_id,
    'drop', i.snapshot,
    'at', i.created_at,
    'redeemedAt', i.redeemed_at,
    'redemption', (select jsonb_build_object('code', r.code, 'expiresAt', r.expires_at)
                   from public.redemptions r
                   where r.item_id = i.id and r.player_id = i.owner_id and r.confirmed_at is null and r.expires_at > now()
                   order by r.id desc limit 1),
    'onMap', (select jsonb_build_object('lat', l.lat, 'lng', l.lng, 'expiresAt', l.expires_at)
              from public.loose_items l where l.item_id = i.id));
$$;

create function public.player_json(p_user uuid)
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
    'questsDone', (select count(*) from public.quest_progress g where g.user_id = p.id and g.completed_at is not null),
    'eventsDone', (select count(*) from public.event_progress g where g.user_id = p.id and g.completed_at is not null))
  from public.profiles p
  left join public.player_stats s on s.user_id = p.id
  where p.id = p_user;
$$;

revoke execute on function private.point(double precision, double precision) from public, anon, authenticated;
revoke execute on function private.event_live(public.events) from public, anon, authenticated;
revoke execute on function private.rarity_roll(text, text, uuid) from public, anon, authenticated;
revoke execute on function private.drop_shown(text, uuid) from public, anon, authenticated;
revoke execute on function private.drop_snapshot(public.drops) from public, anon, authenticated;
revoke execute on function private.award(uuid, integer, integer, text, text, text, text) from public, anon, authenticated;
revoke execute on function private.capture_xp(text, text) from public, anon, authenticated;
revoke execute on function private.change_stock(text, integer) from public, anon, authenticated;
revoke execute on function public.item_to_json(public.inventory) from public, anon, authenticated;
revoke execute on function public.player_json(uuid) from public, anon, authenticated;

-- An event as the app and its owner see it, with a player's progress.
create function public.event_to_json(e public.events, p_user uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'id', e.id,
    'title', e.title,
    'description', e.description,
    'format', e.format,
    'startsAt', e.starts_at,
    'endsAt', e.ends_at,
    'live', private.event_live(e),
    'paused', e.paused,
    'stopXp', e.stop_xp,
    'bonusXp', e.bonus_xp,
    'bonusPoints', e.bonus_points,
    'owner', (select jsonb_build_object('name', coalesce(p.display_name, 'Someone')) from public.profiles p where p.id = e.owner_id),
    'reward', (select jsonb_build_object('dropId', d.id, 'title', d.title, 'savings', o.savings,
                                         'remaining', greatest(o.quantity - o.claimed, 0))
               from public.drops d join public.offers o on o.drop_id = d.id
               where d.id = e.reward_drop_id and d.type = 'offer'),
    'stops', coalesce((select jsonb_agg(jsonb_build_object(
                          'position', s.position,
                          'dropId', s.drop_id,
                          'drop', case when public.drop_on_map(d) then public.drop_to_json(d) end)
                        order by s.position)
                      from public.event_stops s join public.drops d on d.id = s.drop_id
                      where s.event_id = e.id), '[]'::jsonb),
    'progress', (select jsonb_build_object('found', to_jsonb(g.found), 'startedAt', g.started_at, 'completedAt', g.completed_at)
                 from public.event_progress g where g.event_id = e.id and g.user_id = p_user));
$$;

revoke execute on function public.event_to_json(public.events, uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- The player
-- ---------------------------------------------------------------------------

create function public.my_player()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select public.player_json((select auth.uid()));
$$;

create function public.set_handle(handle text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
  v_handle text := lower(btrim(coalesce(set_handle.handle, '')));
begin
  if me is null then
    raise exception 'sign_in_needed' using errcode = 'P0001';
  end if;
  if v_handle !~ '^[a-z0-9_]{3,20}$' then
    raise exception 'bad_handle' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.profiles p where p.handle = v_handle and p.id <> me) then
    raise exception 'handle_taken' using errcode = 'P0001';
  end if;
  update public.profiles p set handle = v_handle where p.id = me;
  return public.player_json(me);
end;
$$;

-- ---------------------------------------------------------------------------
-- What's around the player
-- ---------------------------------------------------------------------------

-- Drops, items left on the map, quests and events within radius_m (50 to 2000 m)
-- of a spot, nearest first. Anyone can look; signing in adds the player's own
-- progress, and what's shown to them on the day.
create function public.app_nearby(lat double precision, lng double precision, radius_m integer default 500)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
  v_here extensions.geography;
  v_radius integer := least(greatest(coalesce(radius_m, 500), 50), 2000);
begin
  if app_nearby.lat is null or app_nearby.lng is null
     or app_nearby.lat not between -85 and 85 or app_nearby.lng not between -180 and 180 then
    raise exception 'bad_location' using errcode = 'P0001';
  end if;
  v_here := private.point(app_nearby.lat, app_nearby.lng);

  return jsonb_build_object(
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

-- ---------------------------------------------------------------------------
-- Capturing
-- ---------------------------------------------------------------------------

-- Capture a drop where the player is standing. Gives a new item when there's one
-- to give (an offer in stock, under its per-person limit; any other drop once),
-- and moves the player on in its quest and any event it's a stop of. Capturing
-- again something already captured still counts for a quest or event.
create function public.capture(drop_id text, lat double precision, lng double precision, accuracy_m real default 10)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
  v_drop public.drops;
  v_offer public.offers;
  v_stats public.player_stats;
  v_here extensions.geography;
  v_seconds double precision;
  v_limit integer := 1;
  v_take boolean := false;
  v_sold_out boolean := false;
  v_stage record;
  v_progress public.quest_progress;
  v_advance boolean := false;
  v_event record;
  v_event_ids text[] := '{}';
  v_found text[];
  v_total integer;
  v_item public.inventory;
  v_reward public.inventory;
  v_xp integer := 0;
  v_points integer := 0;
  v_gain integer;
  v_quest_json jsonb;
  v_events_json jsonb := '[]'::jsonb;
  v_rewards_json jsonb := '[]'::jsonb;
begin
  if me is null then
    raise exception 'sign_in_needed' using errcode = 'P0001';
  end if;
  if capture.lat is null or capture.lng is null
     or capture.lat not between -85 and 85 or capture.lng not between -180 and 180 then
    raise exception 'bad_location' using errcode = 'P0001';
  end if;
  if coalesce(capture.accuracy_m, 1000) > 100 then
    raise exception 'location_unclear' using errcode = 'P0001';
  end if;
  v_here := private.point(capture.lat, capture.lng);

  -- One capture at a time per player.
  insert into public.player_stats (user_id) values (me) on conflict (user_id) do nothing;
  select * into v_stats from public.player_stats s where s.user_id = me for update;

  select * into v_drop from public.drops d where d.id = capture.drop_id;
  if v_drop.id is null or not public.drop_on_map(v_drop) then
    raise exception 'not_available' using errcode = 'P0001';
  end if;
  if v_drop.owner_id = me then
    raise exception 'own_drop' using errcode = 'P0001';
  end if;

  if extensions.st_distance(v_drop.geom::extensions.geography, v_here)
     > 40 + least(greatest(coalesce(capture.accuracy_m, 0), 0), 30) then
    raise exception 'too_far' using errcode = 'P0001';
  end if;

  if v_stats.last_capture_at > now() - interval '1 hour' then
    v_seconds := greatest(extract(epoch from now() - v_stats.last_capture_at), 1);
    if extensions.st_distance(private.point(v_stats.last_lat, v_stats.last_lng), v_here) / v_seconds > 70 then
      raise exception 'moving_too_fast' using errcode = 'P0001';
    end if;
  end if;

  if (select count(*) from public.inventory i
      where i.captured_by = me and i.source = 'capture' and i.created_at > now() - interval '1 day') >= 100 then
    raise exception 'limit_captures' using errcode = 'P0001';
  end if;

  -- Its quest stage, if it's in an active quest.
  select s.quest_id, s.position, q.stage_count into v_stage
  from public.quest_stages s join public.quests q on q.id = s.quest_id
  where s.drop_id = v_drop.id and q.status = 'active'
  limit 1;
  if v_stage.quest_id is not null then
    select * into v_progress from public.quest_progress g
    where g.quest_id = v_stage.quest_id and g.user_id = me for update;
    if v_stage.position > 1 and coalesce(v_progress.stage, 0) < v_stage.position - 1 then
      raise exception 'quest_locked' using errcode = 'P0001';
    end if;
    v_advance := coalesce(v_progress.stage, 0) = v_stage.position - 1 and v_progress.completed_at is null;
  end if;

  if not private.drop_shown(v_drop.id, me) then
    raise exception 'not_available' using errcode = 'P0001';
  end if;

  -- Events it's a stop of, where it's the player's next find.
  for v_event in
    select e.id, e.format, es.position,
           coalesce(g.found, '{}') as found_ids
    from public.event_stops es
    join public.events e on e.id = es.event_id
    left join public.event_progress g on g.event_id = e.id and g.user_id = me
    where es.drop_id = v_drop.id and private.event_live(e)
      and g.completed_at is null
      and not (v_drop.id = any (coalesce(g.found, '{}')))
  loop
    if v_event.format = 'hunt' or v_event.position = coalesce(array_length(v_event.found_ids, 1), 0) + 1 then
      v_event_ids := v_event_ids || v_event.id;
    end if;
  end loop;

  -- A new item?
  if v_drop.type = 'offer' then
    select * into v_offer from public.offers o where o.drop_id = v_drop.id;
    v_limit := v_offer.per_person;
  end if;
  if (select count(*) from public.inventory i
      where i.drop_id = v_drop.id and i.captured_by = me and i.source = 'capture') < v_limit then
    if v_drop.type = 'offer' then
      v_take := private.change_stock(v_drop.id, 1);
      v_sold_out := not v_take;
    else
      v_take := true;
    end if;
  end if;

  if not v_take and not v_advance and cardinality(v_event_ids) = 0 then
    raise exception '%', case when v_sold_out then 'sold_out' else 'already_captured' end using errcode = 'P0001';
  end if;

  if v_take then
    insert into public.inventory (owner_id, drop_id, business_id, kind, rarity, tradeable, snapshot, source, captured_by)
    values (me, v_drop.id, v_drop.owner_id, v_drop.type, v_offer.rarity, coalesce(v_offer.tradeable, true),
            private.drop_snapshot(v_drop), 'capture', me)
    returning * into v_item;
    v_gain := private.capture_xp(v_drop.type, v_offer.rarity);
    perform private.award(me, v_gain, 0, 'capture', v_drop.id);
    v_xp := v_xp + v_gain;
  end if;

  if v_advance then
    insert into public.quest_progress as g (quest_id, user_id, stage)
    values (v_stage.quest_id, me, v_stage.position)
    on conflict (quest_id, user_id) do update set stage = excluded.stage, updated_at = now()
    returning g.* into v_progress;
    perform private.award(me, 25, 0, 'quest_stage', v_drop.id, v_stage.quest_id);
    v_xp := v_xp + 25;
    if v_stage.position = v_stage.stage_count then
      update public.quest_progress g set completed_at = now()
      where g.quest_id = v_stage.quest_id and g.user_id = me
      returning g.* into v_progress;
      perform private.award(me, 300, 100, 'quest_complete', v_drop.id, v_stage.quest_id);
      v_xp := v_xp + 300;
      v_points := v_points + 100;
    end if;
    v_quest_json := jsonb_build_object('id', v_stage.quest_id, 'stage', v_progress.stage,
                                       'stageCount', v_stage.stage_count, 'completed', v_progress.completed_at is not null);
  end if;

  for v_event in
    select e.*, (select count(*) from public.event_stops x where x.event_id = e.id) as total
    from public.events e where e.id = any (v_event_ids)
  loop
    insert into public.event_progress as g (event_id, user_id, found)
    values (v_event.id, me, array[v_drop.id])
    on conflict (event_id, user_id) do update set found = g.found || v_drop.id
    returning g.found into v_found;
    perform private.award(me, v_event.stop_xp, 0, 'event_stop', v_drop.id, null, v_event.id);
    v_xp := v_xp + v_event.stop_xp;

    if cardinality(v_found) >= v_event.total then
      update public.event_progress g set completed_at = now() where g.event_id = v_event.id and g.user_id = me;
      perform private.award(me, v_event.bonus_xp, v_event.bonus_points, 'event_complete', null, null, v_event.id);
      v_xp := v_xp + v_event.bonus_xp;
      v_points := v_points + v_event.bonus_points;
      -- The reward, while it lasts.
      if v_event.reward_drop_id is not null and private.change_stock(v_event.reward_drop_id, 1) then
        insert into public.inventory (owner_id, drop_id, business_id, kind, rarity, tradeable, snapshot, source, captured_by)
        select me, d.id, d.owner_id, 'offer', o.rarity, o.tradeable, private.drop_snapshot(d), 'reward', me
        from public.drops d join public.offers o on o.drop_id = d.id
        where d.id = v_event.reward_drop_id
        returning * into v_reward;
        if v_reward.id is not null then
          v_rewards_json := v_rewards_json || public.item_to_json(v_reward);
        end if;
      end if;
    end if;
    v_events_json := v_events_json || jsonb_build_object(
      'id', v_event.id, 'found', cardinality(v_found), 'total', v_event.total,
      'completed', cardinality(v_found) >= v_event.total);
  end loop;

  update public.player_stats s set
    last_lat = capture.lat, last_lng = capture.lng, last_capture_at = now(),
    captures = s.captures + case when v_take then 1 else 0 end, updated_at = now()
  where s.user_id = me;

  return jsonb_build_object(
    'item', case when v_item.id is not null then public.item_to_json(v_item) end,
    'xp', v_xp,
    'points', v_points,
    'quest', v_quest_json,
    'events', v_events_json,
    'rewards', v_rewards_json,
    'player', public.player_json(me));
end;
$$;

-- ---------------------------------------------------------------------------
-- The inventory
-- ---------------------------------------------------------------------------

-- What the player holds or has left on the map, and what they redeemed in the last 30 days.
create function public.my_inventory()
returns setof jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select public.item_to_json(i)
  from public.inventory i
  where i.owner_id = (select auth.uid())
    and (i.status in ('held', 'dropped') or (i.status = 'redeemed' and i.redeemed_at > now() - interval '30 days'))
  order by i.created_at desc
  limit 500;
$$;

-- Locks one of the player's items, or says why it can't be used.
create function private.my_item(p_item uuid, p_status text default 'held')
returns public.inventory
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_item public.inventory;
begin
  select * into v_item from public.inventory i where i.id = p_item for update;
  if v_item.id is null or v_item.owner_id is distinct from auth.uid() then
    raise exception 'item_not_found' using errcode = 'P0001';
  end if;
  if v_item.status <> p_status then
    raise exception 'item_not_available' using errcode = 'P0001';
  end if;
  return v_item;
end;
$$;

revoke execute on function private.my_item(uuid, text) from public, anon, authenticated;

-- Put an item up for trade, or take it down.
create function public.set_for_trade(item_id uuid, for_trade boolean)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_item public.inventory := private.my_item(set_for_trade.item_id);
begin
  if set_for_trade.for_trade and not v_item.tradeable then
    raise exception 'not_tradeable' using errcode = 'P0001';
  end if;
  update public.inventory i set for_trade = set_for_trade.for_trade, updated_at = now()
  where i.id = v_item.id returning * into v_item;
  return public.item_to_json(v_item);
end;
$$;

-- Throw an item away. An offer goes back in its business's stock.
create function public.discard_item(item_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_item public.inventory := private.my_item(discard_item.item_id);
begin
  update public.inventory i set status = 'discarded', for_trade = false, updated_at = now() where i.id = v_item.id;
  delete from public.redemptions r where r.item_id = v_item.id and r.confirmed_at is null;
  if v_item.kind = 'offer' then
    perform private.change_stock(v_item.drop_id, -1);
  end if;
end;
$$;

-- Leave an item on the map where the player is, for someone else to pick up.
create function public.drop_item(item_id uuid, lat double precision, lng double precision)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
  v_item public.inventory := private.my_item(drop_item.item_id);
begin
  if drop_item.lat is null or drop_item.lng is null
     or drop_item.lat not between -85 and 85 or drop_item.lng not between -180 and 180 then
    raise exception 'bad_location' using errcode = 'P0001';
  end if;
  if not v_item.tradeable then
    raise exception 'not_tradeable' using errcode = 'P0001';
  end if;
  if (select count(*) from public.loose_items l where l.dropped_by = me) >= 20 then
    raise exception 'limit_dropped' using errcode = 'P0001';
  end if;
  update public.inventory i set status = 'dropped', for_trade = false, updated_at = now()
  where i.id = v_item.id returning * into v_item;
  delete from public.redemptions r where r.item_id = v_item.id and r.confirmed_at is null;
  insert into public.loose_items (item_id, dropped_by, lat, lng, expires_at)
  values (v_item.id, me, drop_item.lat, drop_item.lng, now() + interval '7 days');
  return public.item_to_json(v_item);
end;
$$;

-- Pick up an item someone left on the map (or take back your own).
create function public.pick_up_item(item_id uuid, lat double precision, lng double precision, accuracy_m real default 10)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
  v_loose public.loose_items;
  v_item public.inventory;
begin
  if me is null then
    raise exception 'sign_in_needed' using errcode = 'P0001';
  end if;
  if pick_up_item.lat is null or pick_up_item.lng is null then
    raise exception 'bad_location' using errcode = 'P0001';
  end if;
  if coalesce(pick_up_item.accuracy_m, 1000) > 100 then
    raise exception 'location_unclear' using errcode = 'P0001';
  end if;
  select * into v_loose from public.loose_items l where l.item_id = pick_up_item.item_id for update;
  if v_loose.item_id is null or v_loose.expires_at <= now() then
    raise exception 'not_available' using errcode = 'P0001';
  end if;
  if extensions.st_distance(v_loose.geom::extensions.geography, private.point(pick_up_item.lat, pick_up_item.lng))
     > 40 + least(greatest(coalesce(pick_up_item.accuracy_m, 0), 0), 30) then
    raise exception 'too_far' using errcode = 'P0001';
  end if;

  delete from public.loose_items l where l.item_id = v_loose.item_id;
  update public.inventory i set
    owner_id = me, status = 'held',
    source = case when v_loose.dropped_by = me then i.source else 'pick_up' end,
    updated_at = now()
  where i.id = v_loose.item_id and i.status = 'dropped'
  returning * into v_item;
  if v_item.id is null then
    raise exception 'not_available' using errcode = 'P0001';
  end if;

  insert into public.player_stats (user_id) values (me) on conflict (user_id) do nothing;
  if v_loose.dropped_by <> me then
    perform private.award(me, 5, 0, 'pick_up', v_item.drop_id);
  end if;
  return jsonb_build_object('item', public.item_to_json(v_item), 'xp', case when v_loose.dropped_by <> me then 5 else 0 end,
                            'player', public.player_json(me));
end;
$$;

-- ---------------------------------------------------------------------------
-- Redeeming
-- ---------------------------------------------------------------------------

-- The player taps Redeem: a 6-digit code for the business, good for 10 minutes.
-- Asking again while one is good returns the same code.
create function public.start_redemption(item_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_item public.inventory := private.my_item(start_redemption.item_id);
  v_code text;
  v_bytes bytea;
  v_row public.redemptions;
begin
  if v_item.kind <> 'offer' then
    raise exception 'not_an_offer' using errcode = 'P0001';
  end if;
  if v_item.business_id is null then
    raise exception 'offer_gone' using errcode = 'P0001';
  end if;

  select * into v_row from public.redemptions r
  where r.item_id = v_item.id and r.player_id = v_item.owner_id and r.confirmed_at is null and r.expires_at > now()
  order by r.id desc limit 1;

  if v_row.id is null then
    delete from public.redemptions r
    where r.business_id = v_item.business_id and r.confirmed_at is null and r.expires_at <= now();
    loop
      v_bytes := decode(replace(gen_random_uuid()::text, '-', ''), 'hex');
      v_code := lpad(((get_byte(v_bytes, 0) * 65536 + get_byte(v_bytes, 1) * 256 + get_byte(v_bytes, 2)) % 1000000)::text, 6, '0');
      exit when not exists (select 1 from public.redemptions r
                            where r.business_id = v_item.business_id and r.code = v_code and r.confirmed_at is null);
    end loop;
    insert into public.redemptions (item_id, player_id, business_id, code, expires_at)
    values (v_item.id, v_item.owner_id, v_item.business_id, v_code, now() + interval '10 minutes')
    returning * into v_row;
  end if;

  return jsonb_build_object(
    'code', v_row.code,
    'expiresAt', v_row.expires_at,
    'item', public.item_to_json(v_item),
    'business', (select coalesce(p.display_name, 'the business') from public.profiles p where p.id = v_item.business_id));
end;
$$;

-- The business types the player's code into the website. This is what redeems it.
create function public.confirm_redemption(code text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
  v_code text := regexp_replace(coalesce(confirm_redemption.code, ''), '[^0-9]', '', 'g');
  v_row public.redemptions;
  v_item public.inventory;
begin
  if me is null then
    raise exception 'sign_in_needed' using errcode = 'P0001';
  end if;
  if v_code !~ '^[0-9]{6}$' then
    raise exception 'bad_code' using errcode = 'P0001';
  end if;
  select * into v_row from public.redemptions r
  where r.business_id = me and r.code = v_code and r.confirmed_at is null and r.expires_at > now()
  for update;
  if v_row.id is null then
    raise exception 'code_not_found' using errcode = 'P0001';
  end if;
  update public.inventory i set status = 'redeemed', redeemed_at = now(), for_trade = false, updated_at = now()
  where i.id = v_row.item_id and i.owner_id = v_row.player_id and i.status = 'held'
  returning * into v_item;
  if v_item.id is null then
    raise exception 'code_not_found' using errcode = 'P0001';
  end if;
  update public.redemptions r set confirmed_at = now() where r.id = v_row.id;

  perform set_config('hololoco.system', 'on', true);
  update public.offers o set redeemed = o.redeemed + 1 where o.drop_id = v_item.drop_id;
  perform set_config('hololoco.system', '', true);

  return jsonb_build_object(
    'title', v_item.snapshot ->> 'title',
    'savings', v_item.snapshot -> 'offer' ->> 'savings',
    'terms', v_item.snapshot -> 'offer' ->> 'terms',
    'player', (select coalesce(p.handle, p.display_name, 'A player') from public.profiles p where p.id = v_row.player_id),
    'at', now());
end;
$$;

-- The business's redemptions in the last 30 days.
create function public.recent_redemptions()
returns setof jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'at', r.confirmed_at,
    'title', i.snapshot ->> 'title',
    'savings', i.snapshot -> 'offer' ->> 'savings',
    'player', coalesce(p.handle, p.display_name, 'A player'))
  from public.redemptions r
  join public.inventory i on i.id = r.item_id
  left join public.profiles p on p.id = r.player_id
  where r.business_id = (select auth.uid()) and r.confirmed_at > now() - interval '30 days'
  order by r.confirmed_at desc
  limit 100;
$$;

-- ---------------------------------------------------------------------------
-- Trading
-- ---------------------------------------------------------------------------

-- Another player's name, level, and the items they've put up for trade.
create function public.player_shelf(handle text)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select public.player_json(p.id) - 'captures' || jsonb_build_object(
    'items', coalesce((select jsonb_agg(jsonb_build_object(
                          'id', i.id, 'kind', i.kind, 'rarity', i.rarity, 'title', i.snapshot ->> 'title', 'drop', i.snapshot)
                        order by i.created_at desc)
                      from public.inventory i
                      where i.owner_id = p.id and i.status = 'held' and i.for_trade and i.tradeable), '[]'::jsonb))
  from public.profiles p
  where p.handle = lower(btrim(player_shelf.handle)) and (select auth.uid()) is not null;
$$;

-- Offer some of your items for some of another player's (or none: a gift).
create function public.propose_trade(to_handle text, give uuid[], ask uuid[] default '{}')
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
  v_to uuid;
  v_trade uuid;
  v_give uuid[] := array(select distinct x from unnest(coalesce(propose_trade.give, '{}')) x);
  v_ask uuid[] := array(select distinct x from unnest(coalesce(propose_trade.ask, '{}')) x);
begin
  if me is null then
    raise exception 'sign_in_needed' using errcode = 'P0001';
  end if;
  select p.id into v_to from public.profiles p where p.handle = lower(btrim(coalesce(to_handle, '')));
  if v_to is null then
    raise exception 'player_not_found' using errcode = 'P0001';
  end if;
  if v_to = me then
    raise exception 'trade_with_self' using errcode = 'P0001';
  end if;
  if cardinality(v_give) not between 1 and 5 or cardinality(v_ask) > 5 then
    raise exception 'bad_trade' using errcode = 'P0001';
  end if;
  if (select count(*) from public.inventory i
      where i.id = any (v_give) and i.owner_id = me and i.status = 'held' and i.tradeable) <> cardinality(v_give)
     or (select count(*) from public.inventory i
         where i.id = any (v_ask) and i.owner_id = v_to and i.status = 'held' and i.tradeable and i.for_trade) <> cardinality(v_ask) then
    raise exception 'item_not_available' using errcode = 'P0001';
  end if;
  if (select count(*) from public.trades t where t.from_id = me and t.status = 'open' and t.expires_at > now()) >= 10 then
    raise exception 'limit_trades' using errcode = 'P0001';
  end if;

  insert into public.trades (from_id, to_id) values (me, v_to) returning id into v_trade;
  insert into public.trade_items (trade_id, item_id, side)
  select v_trade, x, 'give' from unnest(v_give) x
  union all
  select v_trade, x, 'get' from unnest(v_ask) x;
  return jsonb_build_object('id', v_trade, 'status', 'open');
end;
$$;

-- Accept or decline a trade offered to you. If an item in it has changed hands
-- or been used since, the trade fails and nothing moves.
create function public.answer_trade(trade_id uuid, accept boolean)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
  v_trade public.trades;
  v_ok boolean;
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

  delete from public.redemptions r
  where r.confirmed_at is null and r.item_id in (select x.item_id from public.trade_items x where x.trade_id = v_trade.id);
  update public.inventory i set
    owner_id = case x.side when 'give' then v_trade.to_id else v_trade.from_id end,
    source = 'trade', for_trade = false, updated_at = now()
  from public.trade_items x
  where x.trade_id = v_trade.id and x.item_id = i.id;
  update public.trades t set status = 'accepted', decided_at = now() where t.id = v_trade.id;
  return jsonb_build_object('id', v_trade.id, 'status', 'accepted');
end;
$$;

create function public.cancel_trade(trade_id uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.trades t set status = 'cancelled', decided_at = now()
  where t.id = cancel_trade.trade_id and t.from_id = (select auth.uid()) and t.status = 'open';
$$;

-- The player's open trades, both ways, and those decided in the last 14 days.
create function public.my_trades()
returns setof jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'id', t.id,
    'status', case when t.status = 'open' and t.expires_at <= now() then 'expired' else t.status end,
    'fromMe', t.from_id = (select auth.uid()),
    'other', (select jsonb_build_object('handle', p.handle, 'name', p.display_name)
              from public.profiles p where p.id = case when t.from_id = (select auth.uid()) then t.to_id else t.from_id end),
    'give', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'kind', i.kind, 'rarity', i.rarity,
                                                         'title', i.snapshot ->> 'title', 'drop', i.snapshot))
                      from public.trade_items x join public.inventory i on i.id = x.item_id
                      where x.trade_id = t.id and x.side = 'give'), '[]'::jsonb),
    'get', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'kind', i.kind, 'rarity', i.rarity,
                                                        'title', i.snapshot ->> 'title', 'drop', i.snapshot))
                     from public.trade_items x join public.inventory i on i.id = x.item_id
                     where x.trade_id = t.id and x.side = 'get'), '[]'::jsonb),
    'at', t.created_at,
    'expiresAt', t.expires_at,
    'decidedAt', t.decided_at)
  from public.trades t
  where (select auth.uid()) in (t.from_id, t.to_id)
    and (t.status = 'open' or t.decided_at > now() - interval '14 days')
  order by t.created_at desc
  limit 100;
$$;

-- ---------------------------------------------------------------------------
-- Quests and events, for the player
-- ---------------------------------------------------------------------------

-- Quests the player has started, unfinished first.
create function public.my_quests()
returns setof jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select public.quest_to_json(q) || jsonb_build_object(
    'progress', jsonb_build_object('stage', g.stage, 'startedAt', g.started_at, 'completedAt', g.completed_at))
  from public.quest_progress g join public.quests q on q.id = g.quest_id
  where g.user_id = (select auth.uid())
  order by g.completed_at is not null, g.updated_at desc
  limit 100;
$$;

create function public.public_event(event_id text)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select public.event_to_json(e, (select auth.uid()))
  from public.events e
  where e.id = event_id and not e.paused
    and not exists (select 1 from public.profiles p where p.id = e.owner_id and p.strikes >= 3);
$$;

-- ---------------------------------------------------------------------------
-- Events, for the business
-- ---------------------------------------------------------------------------

-- Create or change an event: { id?, title, description, format, startsAt, endsAt,
-- stopXp, bonusXp, bonusPoints, rewardDropId, paused, stops: [dropId, …] }.
create function public.save_event(payload jsonb)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
  v_id text := nullif(payload ->> 'id', '');
  v_stops text[];
  v_reward text := nullif(payload ->> 'rewardDropId', '');
  v_standing text;
begin
  if me is null then
    raise exception 'sign_in_needed' using errcode = 'P0001';
  end if;
  if not public.is_staff() then
    v_standing := public.account_standing(me);
    if v_standing = 'suspended' then
      raise exception 'account_suspended' using errcode = 'P0001';
    end if;
    if not (public.plan_of(me)).events then
      raise exception 'plan_events' using errcode = 'P0001';
    end if;
    if v_standing <> 'good' then
      raise exception 'account_under_review' using errcode = 'P0001';
    end if;
  end if;

  if jsonb_typeof(payload -> 'stops') <> 'array' then
    raise exception 'event_stops' using errcode = 'P0001';
  end if;
  v_stops := array(select jsonb_array_elements_text(payload -> 'stops'));
  if cardinality(v_stops) not between 2 and 20
     or (select count(distinct x) from unnest(v_stops) x) <> cardinality(v_stops)
     or (select count(*) from public.drops d where d.id = any (v_stops) and d.owner_id = me and d.review <> 'rejected')
        <> cardinality(v_stops) then
    raise exception 'event_stops' using errcode = 'P0001';
  end if;
  if v_reward is not null and not exists (select 1 from public.drops d
                                          where d.id = v_reward and d.owner_id = me and d.type = 'offer') then
    raise exception 'event_reward' using errcode = 'P0001';
  end if;
  if (select count(*) from public.events e where e.owner_id = me and e.ends_at > now() and e.id is distinct from v_id) >= 20 then
    raise exception 'limit_events' using errcode = 'P0001';
  end if;

  if v_id is null then
    insert into public.events (owner_id, title, description, format, starts_at, ends_at, stop_xp, bonus_xp, bonus_points,
                               reward_drop_id, paused)
    values (me, btrim(payload ->> 'title'), btrim(coalesce(payload ->> 'description', '')), payload ->> 'format',
            (payload ->> 'startsAt')::timestamptz, (payload ->> 'endsAt')::timestamptz,
            coalesce((payload ->> 'stopXp')::integer, 25), coalesce((payload ->> 'bonusXp')::integer, 300),
            coalesce((payload ->> 'bonusPoints')::integer, 50), v_reward, coalesce((payload ->> 'paused')::boolean, false))
    returning id into v_id;
  else
    update public.events e set
      title = btrim(payload ->> 'title'),
      description = btrim(coalesce(payload ->> 'description', '')),
      format = payload ->> 'format',
      starts_at = (payload ->> 'startsAt')::timestamptz,
      ends_at = (payload ->> 'endsAt')::timestamptz,
      stop_xp = coalesce((payload ->> 'stopXp')::integer, 25),
      bonus_xp = coalesce((payload ->> 'bonusXp')::integer, 300),
      bonus_points = coalesce((payload ->> 'bonusPoints')::integer, 50),
      reward_drop_id = v_reward,
      paused = coalesce((payload ->> 'paused')::boolean, false),
      updated_at = now()
    where e.id = v_id and e.owner_id = me
    returning e.id into v_id;
    if v_id is null then
      raise exception 'not_found' using errcode = 'P0001';
    end if;
    delete from public.event_stops s where s.event_id = v_id;
  end if;

  insert into public.event_stops (event_id, position, drop_id)
  select v_id, x.n, x.drop_id from unnest(v_stops) with ordinality as x(drop_id, n);
  return v_id;
end;
$$;

create function public.delete_event(event_id text)
returns void
language sql
security definer
set search_path = ''
as $$
  delete from public.events e where e.id = event_id and e.owner_id = (select auth.uid());
$$;

-- The business's events, newest first, with how many players started and finished.
create function public.my_events()
returns setof jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select public.event_to_json(e, null) - 'progress' || jsonb_build_object(
    'started', (select count(*) from public.event_progress g where g.event_id = e.id),
    'finished', (select count(*) from public.event_progress g where g.event_id = e.id and g.completed_at is not null))
  from public.events e
  where e.owner_id = (select auth.uid())
  order by e.starts_at desc
  limit 100;
$$;

-- ---------------------------------------------------------------------------
-- Owners see how their offers do.
-- ---------------------------------------------------------------------------

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
    'photoCheck', (select a.scan_state from public.assets a where a.id = d.asset_id and a.kind = 'photo'),
    'quest', (select jsonb_build_object('id', q.id, 'name', q.name, 'position', s.position, 'stageCount', q.stage_count)
              from public.quest_stages s join public.quests q on q.id = s.quest_id
              where s.drop_id = d.id and q.status = 'active'
              limit 1),
    'stats', jsonb_build_object(
      'captures', (select count(*) from public.inventory i where i.drop_id = d.id and i.source in ('capture', 'reward')),
      'redeemed', (select o.redeemed from public.offers o where o.drop_id = d.id)))
  from public.drops d
  where d.owner_id = (select auth.uid())
  order by d.created_at desc;
$$;

-- ---------------------------------------------------------------------------
-- Upkeep, every 10 minutes
-- ---------------------------------------------------------------------------

-- Items nobody picked up go back to whoever left them; old trades expire; old codes go.
create function private.play_upkeep()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_returned integer;
  v_expired integer;
begin
  with gone as (
    delete from public.loose_items l where l.expires_at <= now() returning l.item_id, l.dropped_by
  )
  update public.inventory i set owner_id = gone.dropped_by, status = 'held', updated_at = now()
  from gone where i.id = gone.item_id and i.status = 'dropped';
  get diagnostics v_returned = row_count;

  update public.trades t set status = 'expired', decided_at = now() where t.status = 'open' and t.expires_at <= now();
  get diagnostics v_expired = row_count;

  delete from public.redemptions r where r.confirmed_at is null and r.expires_at < now() - interval '1 day';
  return jsonb_build_object('returned', v_returned, 'tradesExpired', v_expired);
end;
$$;

revoke execute on function private.play_upkeep() from public, anon, authenticated;

select cron.schedule('play-upkeep', '*/10 * * * *', 'select private.play_upkeep()');

-- ---------------------------------------------------------------------------
-- Who can call what
-- ---------------------------------------------------------------------------

revoke execute on function public.level_for(integer) from public;
revoke execute on function public.xp_for_level(integer) from public;
revoke execute on function public.my_player() from public, anon;
revoke execute on function public.set_handle(text) from public, anon;
revoke execute on function public.app_nearby(double precision, double precision, integer) from public;
revoke execute on function public.capture(text, double precision, double precision, real) from public, anon;
revoke execute on function public.my_inventory() from public, anon;
revoke execute on function public.set_for_trade(uuid, boolean) from public, anon;
revoke execute on function public.discard_item(uuid) from public, anon;
revoke execute on function public.drop_item(uuid, double precision, double precision) from public, anon;
revoke execute on function public.pick_up_item(uuid, double precision, double precision, real) from public, anon;
revoke execute on function public.start_redemption(uuid) from public, anon;
revoke execute on function public.confirm_redemption(text) from public, anon;
revoke execute on function public.recent_redemptions() from public, anon;
revoke execute on function public.player_shelf(text) from public, anon;
revoke execute on function public.propose_trade(text, uuid[], uuid[]) from public, anon;
revoke execute on function public.answer_trade(uuid, boolean) from public, anon;
revoke execute on function public.cancel_trade(uuid) from public, anon;
revoke execute on function public.my_trades() from public, anon;
revoke execute on function public.my_quests() from public, anon;
revoke execute on function public.public_event(text) from public;
revoke execute on function public.save_event(jsonb) from public, anon;
revoke execute on function public.delete_event(text) from public, anon;
revoke execute on function public.my_events() from public, anon;

grant execute on function public.level_for(integer) to anon, authenticated;
grant execute on function public.xp_for_level(integer) to anon, authenticated;
grant execute on function public.app_nearby(double precision, double precision, integer) to anon, authenticated;
grant execute on function public.public_event(text) to anon, authenticated;
grant execute on function public.my_player() to authenticated;
grant execute on function public.set_handle(text) to authenticated;
grant execute on function public.capture(text, double precision, double precision, real) to authenticated;
grant execute on function public.my_inventory() to authenticated;
grant execute on function public.set_for_trade(uuid, boolean) to authenticated;
grant execute on function public.discard_item(uuid) to authenticated;
grant execute on function public.drop_item(uuid, double precision, double precision) to authenticated;
grant execute on function public.pick_up_item(uuid, double precision, double precision, real) to authenticated;
grant execute on function public.start_redemption(uuid) to authenticated;
grant execute on function public.confirm_redemption(text) to authenticated;
grant execute on function public.recent_redemptions() to authenticated;
grant execute on function public.player_shelf(text) to authenticated;
grant execute on function public.propose_trade(text, uuid[], uuid[]) to authenticated;
grant execute on function public.answer_trade(uuid, boolean) to authenticated;
grant execute on function public.cancel_trade(uuid) to authenticated;
grant execute on function public.my_trades() to authenticated;
grant execute on function public.my_quests() to authenticated;
grant execute on function public.save_event(jsonb) to authenticated;
grant execute on function public.delete_event(text) to authenticated;
grant execute on function public.my_events() to authenticated;
