-- Found events: games, concerts, comedy, plays, festivals, business events,
-- giveaways and deals around town that Hololoco finds on the web by itself, for
-- staff to approve onto the map.
--
-- The find-events Edge Function does the finding. Once a day the database queues a
-- run; the function sends one Claude request per topic (with web search) as a
-- Message Batch, and when the batch is done it places each event at its address
-- and saves it here as pending. Staff go through them on the website's
-- /review/found page. Approving one makes an ordinary drop, owned by the
-- "Hololoco Events" account and linked back to the event, so the app shows it
-- like any other drop until the event ends.

create extension if not exists pg_trgm with schema extensions;

-- ---------------------------------------------------------------------------
-- Where Hololoco looks. Austin first.
-- ---------------------------------------------------------------------------

create table public.found_areas (
  id text primary key check (id ~ '^[a-z0-9-]{2,30}$'),
  name text not null,
  lat double precision not null,
  lng double precision not null,
  radius_km real not null check (radius_km between 1 and 200),
  time_zone text not null check (public.is_time_zone(time_zone)),
  active boolean not null default true
);

insert into public.found_areas (id, name, lat, lng, radius_km, time_zone)
values ('austin', 'Austin, Texas', 30.2672, -97.7431, 40, 'America/Chicago');

-- ---------------------------------------------------------------------------
-- Runs and searches
-- ---------------------------------------------------------------------------

-- One run: a search of an area. The daily job searches the topics that are due;
-- a run staff ask for searches every topic.
create table public.found_runs (
  id bigint generated always as identity primary key,
  area_id text not null references public.found_areas (id),
  status text not null default 'queued' check (status in ('queued', 'running', 'done')),
  all_topics boolean not null default false,
  -- Who asked for it: null for the daily job.
  requested_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  finished_at timestamptz
);

create index found_runs_open_idx on public.found_runs (status) where status <> 'done';

-- One topic in a run ("concerts and live music"): waiting to be sent, in a batch,
-- waiting to be sent again to carry on, back with events being placed, or finished.
create table public.found_searches (
  id bigint generated always as identity primary key,
  run_id bigint not null references public.found_runs (id) on delete cascade,
  topic text not null,
  status text not null default 'queued'
    check (status in ('queued', 'submitted', 'continue', 'placing', 'done', 'failed')),
  -- Requests sent so far: a search that pauses or forgets to save carries on in the next batch.
  round smallint not null default 0,
  batch_id text,
  -- The conversation so far, while it has to carry on in another batch.
  messages jsonb,
  -- The events Claude saved, while they're being placed, and how far placing got.
  found jsonb,
  placed integer not null default 0,
  added integer not null default 0,
  duplicates integer not null default 0,
  skipped integer not null default 0,
  usage jsonb not null default '{}'::jsonb,
  cost_cents numeric(10, 2) not null default 0,
  error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index found_searches_open_idx on public.found_searches (status) where status not in ('done', 'failed');
create index found_searches_run_idx on public.found_searches (run_id);
create index found_searches_topic_idx on public.found_searches (topic, created_at desc);

-- ---------------------------------------------------------------------------
-- Venues and events
-- ---------------------------------------------------------------------------

-- Places events happen, looked up once. When staff move an event's pin, its venue
-- moves too, so later events there land on the corrected spot.
create table public.found_venues (
  key text primary key,
  name text not null,
  address text not null default '',
  lat double precision not null,
  lng double precision not null,
  -- address: from the street address. estimate: Claude's own estimate. staff: placed by a person.
  source text not null check (source in ('address', 'estimate', 'staff')),
  updated_at timestamptz not null default now()
);

create table public.found_events (
  id text primary key default public.new_drop_id(),
  area_id text not null references public.found_areas (id),
  search_id bigint references public.found_searches (id) on delete set null,
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected', 'expired')),
  category text not null check (category in (
    'sports', 'music', 'comedy', 'theater', 'arts', 'festival', 'food',
    'business', 'community', 'family', 'giveaway', 'deal', 'other')),
  title text not null check (char_length(btrim(title)) between 1 and 70),
  summary text not null default '' check (char_length(summary) <= 400),
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  all_day boolean not null default false,
  -- Anything about the time worth knowing: "Doors 7 pm", "Every Saturday", "Runs through Dec 20".
  time_note text not null default '' check (char_length(time_note) <= 120),
  venue text not null default '' check (char_length(venue) <= 120),
  address text not null default '' check (char_length(address) <= 200),
  venue_key text,
  lat double precision not null check (lat between -85 and 85),
  lng double precision not null check (lng between -180 and 180),
  -- How the spot was found: address (its street address), venue (a venue already
  -- placed), estimate (Claude's own estimate, worth a look) or staff (placed by a person).
  placed_by text not null check (placed_by in ('address', 'venue', 'estimate', 'staff')),
  geom extensions.geometry(Point, 4326)
    generated always as (extensions.st_setsrid(extensions.st_makepoint(lng, lat), 4326)) stored,
  price text not null default '' check (char_length(price) <= 80),
  free boolean not null default false,
  url text check (url is null or url ~ '^https?://'),
  ticket_url text check (ticket_url is null or ticket_url ~ '^https?://'),
  sources text[] not null default '{}',
  organizer text not null default '' check (char_length(organizer) <= 120),
  confidence text not null default 'medium' check (confidence in ('high', 'medium', 'low')),
  -- For the reviewer, from whoever found it.
  note text not null default '' check (char_length(note) <= 400),
  -- Area, title and local date, normalised: the same event found twice has the same key.
  dedupe_key text not null unique,
  reviewed_by uuid references public.profiles (id) on delete set null,
  reviewed_at timestamptz,
  reject_reason text check (reject_reason is null or char_length(reject_reason) <= 200),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint found_ends_after_start check (ends_at > starts_at)
);

create index found_events_status_idx on public.found_events (status, starts_at);
create index found_events_geom_idx on public.found_events using gist (geom);
create index found_events_title_idx on public.found_events using gin (title extensions.gin_trgm_ops);
create index found_events_venue_idx on public.found_events (venue_key);

-- Nothing here is read or written directly: staff use the functions below, and the
-- Edge Function uses its own database connection.
alter table public.found_areas enable row level security;
alter table public.found_runs enable row level security;
alter table public.found_searches enable row level security;
alter table public.found_venues enable row level security;
alter table public.found_events enable row level security;
revoke all on table public.found_areas, public.found_runs, public.found_searches,
  public.found_venues, public.found_events from anon, authenticated;

-- An approved event is a drop that points back to it.
alter table public.drops add column found_event_id text unique references public.found_events (id) on delete set null;

-- ---------------------------------------------------------------------------
-- The account that owns approved events' drops
-- ---------------------------------------------------------------------------

-- Nobody signs in as it: no password, an address that can't receive mail, and banned.
do $$
declare
  v_id uuid := gen_random_uuid();
begin
  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                          confirmation_token, recovery_token, email_change_token_new, email_change,
                          raw_app_meta_data, raw_user_meta_data, created_at, updated_at, banned_until)
  values ('00000000-0000-0000-0000-000000000000', v_id, 'authenticated', 'authenticated',
          'event-finder@hololoco.invalid', '', now(), '', '', '', '',
          '{"provider": "email", "providers": ["email"]}', '{}', now(), now(), '2999-01-01');
  update public.profiles
     set display_name = 'Hololoco Events', kind = 'business', adult_confirmed_at = now()
   where id = v_id;
  insert into private.settings (name, value) values ('found_owner', v_id::text);
end;
$$;

create function private.found_owner()
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select s.value::uuid from private.settings s where s.name = 'found_owner';
$$;

revoke execute on function private.found_owner() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- JSON
-- ---------------------------------------------------------------------------

-- What anyone sees about an approved event, inside its drop.
create function public.found_public_json(e public.found_events)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'id', e.id,
    'category', e.category,
    'start', to_char(e.starts_at at time zone a.time_zone, 'YYYY-MM-DD"T"HH24:MI'),
    'end', to_char(e.ends_at at time zone a.time_zone, 'YYYY-MM-DD"T"HH24:MI'),
    'allDay', e.all_day,
    'timeNote', e.time_note,
    'venue', e.venue,
    'address', e.address,
    'price', e.price,
    'free', e.free,
    'url', e.url,
    'ticketUrl', e.ticket_url,
    'organizer', e.organizer)
  from public.found_areas a where a.id = e.area_id;
$$;

-- Everything, for staff.
create function public.found_event_to_json(e public.found_events)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select public.found_public_json(e) || jsonb_build_object(
    'status', e.status,
    'title', e.title,
    'summary', e.summary,
    'timeZone', a.time_zone,
    'placement', jsonb_build_object('lat', e.lat, 'lng', e.lng),
    'placedBy', e.placed_by,
    'sources', to_jsonb(e.sources),
    'confidence', e.confidence,
    'note', e.note,
    'topic', (select s.topic from public.found_searches s where s.id = e.search_id),
    'dropId', (select d.id from public.drops d where d.found_event_id = e.id),
    'reviewedAt', e.reviewed_at,
    'rejectReason', e.reject_reason,
    'foundAt', e.created_at)
  from public.found_areas a where a.id = e.area_id;
$$;

revoke execute on function public.found_public_json(public.found_events) from public, anon;
revoke execute on function public.found_event_to_json(public.found_events) from public, anon, authenticated;

-- The drop JSON everyone reads, now with the event it came from.
create or replace function public.drop_to_json(d public.drops)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'id', d.id,
    'type', d.type,
    'title', d.title,
    'description', d.description,
    'objectId', d.object_id,
    'asset', (select jsonb_build_object(
                'id', a.id, 'kind', a.kind, 'status', a.status,
                'model', a.public_model_path, 'thumbnail', a.public_thumbnail_path, 'photo', a.public_photo_path)
              from public.assets a where a.id = d.asset_id),
    'offer', (select jsonb_build_object(
                'savings', o.savings, 'terms', o.terms, 'quantity', o.quantity,
                'remaining', greatest(o.quantity - o.claimed, 0), 'perPersonLimit', o.per_person,
                'rarity', o.rarity, 'inQuests', o.in_quests,
                'kind', o.kind, 'category', o.category, 'tradeable', o.tradeable,
                'valueCents', o.value_cents, 'decayPercent', o.decay_percent, 'decayDays', o.decay_days,
                'valueSince', o.created_at,
                'valueNowCents', public.offer_value_now(o.value_cents, o.decay_percent, o.decay_days, o.created_at))
              from public.offers o where o.drop_id = d.id and d.type = 'offer'),
    'found', (select public.found_public_json(e) from public.found_events e where e.id = d.found_event_id),
    'placement', jsonb_build_object('lat', d.lat, 'lng', d.lng, 'height', d.height, 'size', d.size, 'turn', d.turn),
    'timeZone', d.time_zone,
    'timing', case d.timing
      when 'always' then jsonb_build_object('kind', 'always')
      when 'once' then jsonb_build_object(
        'kind', 'once',
        'start', to_char(d.starts_at at time zone d.time_zone, 'YYYY-MM-DD"T"HH24:MI'),
        'end', to_char(d.ends_at at time zone d.time_zone, 'YYYY-MM-DD"T"HH24:MI'))
      else jsonb_build_object(
        'kind', 'weekly',
        'blocks', coalesce((
          select jsonb_agg(jsonb_build_object(
                   'days', to_jsonb(b.days),
                   'start', to_char(b.start_time, 'HH24:MI'),
                   'end', to_char(b.end_time, 'HH24:MI')) order by b.id)
          from public.schedule_blocks b where b.drop_id = d.id), '[]'::jsonb))
    end,
    'audience', d.audience,
    'owner', (select jsonb_build_object('name', coalesce(p.display_name, 'Someone'), 'kind', p.kind, 'verified', false)
              from public.profiles p where p.id = d.owner_id),
    'review', d.review,
    'reviewReason', d.review_reason,
    'paused', d.paused,
    'openNow', public.drop_is_open(d),
    'createdAt', d.created_at
  );
$$;

-- ---------------------------------------------------------------------------
-- Saving what the finder heard about (the Edge Function calls this)
-- ---------------------------------------------------------------------------

create function private.found_title_key(p_title text)
returns text
language sql
immutable
set search_path = ''
as $$
  select btrim(regexp_replace(
           regexp_replace(' ' || lower(p_title) || ' ', '[^a-z0-9]+', ' ', 'g'),
           ' (the|a|an|vs|v|at|and|with|live|presents|featuring|feat|ft) ', ' ', 'g'), ' ');
$$;

revoke execute on function private.found_title_key(text) from public, anon, authenticated;

-- One event, already placed by the Edge Function. Returns 'added', 'duplicate' or
-- 'skipped: <why>'. A duplicate adds its source to the event already saved.
create function private.found_save_event(p_search bigint, p_area text, p_event jsonb)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  area public.found_areas;
  v_title text := left(btrim(coalesce(p_event ->> 'title', '')), 70);
  v_starts_text text := btrim(coalesce(p_event ->> 'starts', ''));
  v_ends_text text := nullif(btrim(coalesce(p_event ->> 'ends', '')), '');
  v_all_day boolean;
  v_starts timestamptz;
  v_ends timestamptz;
  v_lat double precision := (p_event ->> 'lat')::double precision;
  v_lng double precision := (p_event ->> 'lng')::double precision;
  v_category text := coalesce(p_event ->> 'category', 'other');
  v_url text := nullif(btrim(coalesce(p_event ->> 'url', '')), '');
  v_ticket text := nullif(btrim(coalesce(p_event ->> 'ticket_url', '')), '');
  v_key text;
  v_existing text;
begin
  select * into area from public.found_areas a where a.id = p_area;
  if area.id is null then
    return 'skipped: unknown area';
  end if;
  if v_title = '' then
    return 'skipped: no title';
  end if;
  if v_lat is null or v_lng is null then
    return 'skipped: no location';
  end if;
  if not extensions.st_dwithin(
       extensions.st_setsrid(extensions.st_makepoint(v_lng, v_lat), 4326)::extensions.geography,
       extensions.st_setsrid(extensions.st_makepoint(area.lng, area.lat), 4326)::extensions.geography,
       area.radius_km * 1000) then
    return 'skipped: outside the area';
  end if;

  -- Local times: "YYYY-MM-DDTHH:MM", or "YYYY-MM-DD" for a day with no time.
  begin
    v_all_day := v_starts_text ~ '^\d{4}-\d{2}-\d{2}$';
    v_starts := (replace(v_starts_text, 'T', ' ')::timestamp) at time zone area.time_zone;
    if v_ends_text is not null then
      v_ends := (replace(v_ends_text, 'T', ' ')::timestamp) at time zone area.time_zone;
      -- A date alone for the end means the end of that day.
      if v_ends_text ~ '^\d{4}-\d{2}-\d{2}$' then
        v_ends := v_ends + interval '1 day';
      end if;
    end if;
  exception when others then
    return 'skipped: unreadable date';
  end;
  if v_ends is null or v_ends <= v_starts then
    v_ends := case
      when v_category in ('giveaway', 'deal') then v_starts + interval '7 days'
      when v_all_day then v_starts + interval '1 day'
      else v_starts + interval '3 hours'
    end;
  end if;
  if v_ends <= now() then
    return 'skipped: already over';
  end if;
  if v_starts > now() + interval '120 days' then
    return 'skipped: too far ahead';
  end if;

  if v_url is not null and v_url !~ '^https?://' then v_url := null; end if;
  if v_ticket is not null and v_ticket !~ '^https?://' then v_ticket := null; end if;
  if v_category not in ('sports', 'music', 'comedy', 'theater', 'arts', 'festival', 'food',
                        'business', 'community', 'family', 'giveaway', 'deal', 'other') then
    v_category := 'other';
  end if;

  v_key := area.id || '|' || private.found_title_key(v_title) || '|'
           || to_char(v_starts at time zone area.time_zone, 'YYYY-MM-DD');

  -- The same event: the same key, or a close title on the same day at the same place.
  select e.id into v_existing
  from public.found_events e
  where e.dedupe_key = v_key
     or (e.area_id = area.id
         and (e.starts_at at time zone area.time_zone)::date = (v_starts at time zone area.time_zone)::date
         and (e.venue_key = (p_event ->> 'venue_key')
              or extensions.st_dwithin(e.geom::extensions.geography,
                   extensions.st_setsrid(extensions.st_makepoint(v_lng, v_lat), 4326)::extensions.geography, 250))
         and extensions.similarity(e.title, v_title) > 0.45)
  limit 1;

  if v_existing is not null then
    update public.found_events e set
      sources = case when v_url is null or v_url = any (e.sources) then e.sources else e.sources || v_url end,
      ticket_url = coalesce(e.ticket_url, v_ticket),
      updated_at = now()
    where e.id = v_existing;
    return 'duplicate';
  end if;

  insert into public.found_events (
    area_id, search_id, category, title, summary, starts_at, ends_at, all_day, time_note,
    venue, address, venue_key, lat, lng, placed_by, price, free, url, ticket_url, sources,
    organizer, confidence, note, dedupe_key)
  values (
    area.id, p_search, v_category, v_title,
    left(btrim(coalesce(p_event ->> 'summary', '')), 400),
    v_starts, v_ends, v_all_day,
    left(btrim(coalesce(p_event ->> 'time_note', '')), 120),
    left(btrim(coalesce(p_event ->> 'venue', '')), 120),
    left(btrim(coalesce(p_event ->> 'address', '')), 200),
    nullif(p_event ->> 'venue_key', ''),
    v_lat, v_lng,
    case when p_event ->> 'placed_by' in ('address', 'venue', 'estimate', 'staff') then p_event ->> 'placed_by' else 'estimate' end,
    left(btrim(coalesce(p_event ->> 'price', '')), 80),
    coalesce((p_event ->> 'free')::boolean, false),
    v_url, v_ticket,
    case when v_url is null then '{}'::text[] else array[v_url] end,
    left(btrim(coalesce(p_event ->> 'organizer', '')), 120),
    case when p_event ->> 'confidence' in ('high', 'medium', 'low') then p_event ->> 'confidence' else 'medium' end,
    left(btrim(coalesce(p_event ->> 'note', '')), 400),
    v_key);
  return 'added';
end;
$$;

revoke execute on function private.found_save_event(bigint, text, jsonb) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Scheduling: a run a day, and a tick while there's work
-- ---------------------------------------------------------------------------

-- Wakes the Edge Function. It does only what the tables say needs doing, so a
-- stray call can't start a search or spend anything.
create function private.send_finder()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_url text;
begin
  select s.decrypted_secret into v_url from vault.decrypted_secrets s where s.name = 'project_url';
  if v_url is null then
    return;
  end if;
  perform net.http_post(
    url := rtrim(v_url, '/') || '/functions/v1/find-events',
    body := jsonb_build_object('action', 'tick'),
    headers := jsonb_build_object('Content-Type', 'application/json'),
    timeout_milliseconds := 10000);
exception when others then
  raise warning 'send_finder: %', sqlerrm;
end;
$$;

revoke execute on function private.send_finder() from public, anon, authenticated;

-- Once a day: queue a run for each area that hasn't had one in the last 20 hours.
create function private.found_daily()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.found_runs (area_id)
  select a.id from public.found_areas a
  where a.active
    and not exists (select 1 from public.found_runs r
                    where r.area_id = a.id and r.created_at > now() - interval '20 hours');
  perform private.found_tick();
end;
$$;

-- Every few minutes: tidy up, and wake the Edge Function if anything is waiting.
create function private.found_tick()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- Events that ended before anyone looked at them.
  update public.found_events e set status = 'expired', updated_at = now()
  where e.status = 'pending' and e.ends_at <= now();

  -- A batch can take up to a day; after that, give up on it.
  update public.found_searches s set status = 'failed', error = coalesce(s.error, 'timed_out'), updated_at = now()
  where s.status in ('submitted', 'continue', 'placing') and s.updated_at < now() - interval '26 hours';
  update public.found_runs r set status = 'done', finished_at = now()
  where r.status = 'running'
    and not exists (select 1 from public.found_searches s
                    where s.run_id = r.id and s.status not in ('done', 'failed'));

  if exists (select 1 from public.found_runs r where r.status <> 'done') then
    perform private.send_finder();
  end if;
end;
$$;

revoke execute on function private.found_daily() from public, anon, authenticated;
revoke execute on function private.found_tick() from public, anon, authenticated;

select cron.schedule('found-daily', '0 11 * * *', 'select private.found_daily()');
select cron.schedule('found-tick', '*/3 * * * *', 'select private.found_tick()');

-- ---------------------------------------------------------------------------
-- Staff
-- ---------------------------------------------------------------------------

-- Found events in one state, with counts of each state and how the finder is doing.
create function public.found_queue(p_status text default 'pending')
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.is_staff() then
    raise exception 'not_allowed' using errcode = 'P0001';
  end if;
  if p_status not in ('pending', 'approved', 'rejected', 'expired') then
    raise exception 'bad_status' using errcode = 'P0001';
  end if;

  return jsonb_build_object(
    'items', coalesce((
      select jsonb_agg(public.found_event_to_json(e)
                       order by case when p_status = 'pending' then e.starts_at end,
                                e.reviewed_at desc nulls last, e.starts_at)
      from (select * from public.found_events e
            where e.status = p_status
            order by case when p_status = 'pending' then e.starts_at end,
                     e.reviewed_at desc nulls last, e.starts_at
            limit 500) e), '[]'::jsonb),
    'counts', (select jsonb_build_object(
                 'pending', count(*) filter (where e.status = 'pending'),
                 'approved', count(*) filter (where e.status = 'approved' and e.ends_at > now()),
                 'rejected', count(*) filter (where e.status = 'rejected'),
                 'expired', count(*) filter (where e.status = 'expired'))
               from public.found_events e),
    'finder', jsonb_build_object(
      'running', exists (select 1 from public.found_runs r where r.status <> 'done'),
      'lastRun', (select jsonb_build_object(
                    'id', r.id, 'status', r.status, 'createdAt', r.created_at, 'finishedAt', r.finished_at,
                    'searches', coalesce((select jsonb_agg(jsonb_build_object(
                                  'topic', s.topic, 'status', s.status, 'added', s.added,
                                  'duplicates', s.duplicates, 'skipped', s.skipped,
                                  'costCents', s.cost_cents, 'error', s.error) order by s.id)
                                from public.found_searches s where s.run_id = r.id), '[]'::jsonb))
                  from public.found_runs r order by r.id desc limit 1),
      'costCents30Days', (select coalesce(sum(s.cost_cents), 0) from public.found_searches s
                          where s.created_at > now() - interval '30 days')));
end;
$$;

-- Approve (puts it on the map), reject, or send back to pending; and optionally move
-- it or retitle it first. Approving an event that's already approved updates its drop.
create function public.review_found(
  found_id text,
  decision text,
  lat double precision default null,
  lng double precision default null,
  title text default null,
  reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  e public.found_events;
  area public.found_areas;
  v_drop text;
  v_title text := nullif(left(btrim(coalesce(review_found.title, '')), 70), '');
  v_object text;
begin
  if not public.is_staff() then
    raise exception 'not_allowed' using errcode = 'P0001';
  end if;
  if decision not in ('approve', 'reject', 'pending', 'move') then
    raise exception 'bad_decision' using errcode = 'P0001';
  end if;

  select * into e from public.found_events f where f.id = found_id for update;
  if e.id is null then
    raise exception 'not_found' using errcode = 'P0001';
  end if;
  select * into area from public.found_areas a where a.id = e.area_id;
  select d.id into v_drop from public.drops d where d.found_event_id = e.id;

  perform set_config('hololoco.system', 'on', true);

  -- A person moving the pin moves the venue too, and every event there still waiting.
  if review_found.lat is not null and review_found.lng is not null
     and (review_found.lat <> e.lat or review_found.lng <> e.lng) then
    if review_found.lat not between -85 and 85 or review_found.lng not between -180 and 180 then
      raise exception 'bad_location' using errcode = 'P0001';
    end if;
    update public.found_events f
       set lat = review_found.lat, lng = review_found.lng, placed_by = 'staff', updated_at = now()
     where f.id = e.id
     returning * into e;
    if e.venue_key is not null then
      insert into public.found_venues (key, name, address, lat, lng, source)
      values (e.venue_key, coalesce(nullif(e.venue, ''), e.address), e.address, e.lat, e.lng, 'staff')
      on conflict (key) do update
        set lat = excluded.lat, lng = excluded.lng, source = 'staff', updated_at = now();
      update public.found_events f
         set lat = e.lat, lng = e.lng, placed_by = 'staff', updated_at = now()
       where f.venue_key = e.venue_key and f.status = 'pending' and f.id <> e.id;
    end if;
  end if;

  if v_title is not null and v_title <> e.title then
    update public.found_events f set title = v_title, updated_at = now() where f.id = e.id returning * into e;
  end if;

  if decision = 'approve' then
    if e.ends_at <= now() then
      raise exception 'already_over' using errcode = 'P0001';
    end if;
    v_object := case e.category
      when 'music' then 'note'
      when 'comedy' then 'heart'
      when 'community' then 'heart'
      when 'family' then 'heart'
      when 'food' then 'pizza'
      when 'business' then 'cup'
      when 'giveaway' then 'gift'
      when 'deal' then 'gift'
      else 'star'
    end;
    if v_drop is null then
      insert into public.drops (owner_id, type, title, description, object_id, lat, lng, height, size, turn,
                                time_zone, timing, starts_at, ends_at, audience, review, found_event_id)
      values (private.found_owner(), 'message', e.title, e.summary, v_object, e.lat, e.lng, 3, 6, 0,
              area.time_zone, 'once', now(), e.ends_at, 'everyone', 'approved', e.id)
      returning id into v_drop;
    else
      update public.drops d
         set title = e.title, description = e.summary, object_id = v_object, lat = e.lat, lng = e.lng,
             ends_at = e.ends_at, review = 'approved', paused = false
       where d.id = v_drop;
    end if;
    update public.found_events f
       set status = 'approved', reviewed_by = auth.uid(), reviewed_at = now(), reject_reason = null, updated_at = now()
     where f.id = e.id
     returning * into e;
  elsif decision in ('reject', 'pending') then
    -- Hidden, not deleted: players may already hold it in their bags.
    if v_drop is not null then
      update public.drops d set review = 'rejected', paused = true where d.id = v_drop;
    end if;
    update public.found_events f
       set status = case when decision = 'reject' then 'rejected' else 'pending' end,
           reviewed_by = case when decision = 'reject' then auth.uid() end,
           reviewed_at = case when decision = 'reject' then now() end,
           reject_reason = case when decision = 'reject' then nullif(left(btrim(coalesce(reason, '')), 200), '') end,
           updated_at = now()
     where f.id = e.id
     returning * into e;
  elsif v_drop is not null then
    -- Only moved or retitled: keep an approved event's drop in step.
    update public.drops d set title = e.title, lat = e.lat, lng = e.lng where d.id = v_drop;
  end if;

  perform set_config('hololoco.system', '', true);
  return public.found_event_to_json(e);
end;
$$;

-- Search every topic now, instead of waiting for tomorrow's run.
create function public.run_finder(area text default 'austin')
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_run bigint;
begin
  if not public.is_staff() then
    raise exception 'not_allowed' using errcode = 'P0001';
  end if;
  if not exists (select 1 from public.found_areas a where a.id = run_finder.area and a.active) then
    raise exception 'not_found' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.found_runs r where r.area_id = run_finder.area and r.status <> 'done') then
    raise exception 'already_running' using errcode = 'P0001';
  end if;
  insert into public.found_runs (area_id, all_topics, requested_by)
  values (run_finder.area, true, auth.uid())
  returning id into v_run;
  perform private.send_finder();
  return jsonb_build_object('runId', v_run);
end;
$$;

revoke execute on function public.found_queue(text) from public, anon;
revoke execute on function public.review_found(text, text, double precision, double precision, text, text) from public, anon;
revoke execute on function public.run_finder(text) from public, anon;
grant execute on function public.found_queue(text) to authenticated;
grant execute on function public.review_found(text, text, double precision, double precision, text, text) to authenticated;
grant execute on function public.run_finder(text) to authenticated;

-- ---------------------------------------------------------------------------
-- The app: approved events around a spot, farther than the player can see
-- ---------------------------------------------------------------------------

-- The app's Events view: what's on around town, not only what's in sight.
create function public.app_found_nearby(lat double precision, lng double precision, radius_m integer default 15000)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
  v_here extensions.geography;
  v_radius integer := least(greatest(coalesce(radius_m, 15000), 500), 50000);
begin
  if app_found_nearby.lat is null or app_found_nearby.lng is null
     or app_found_nearby.lat not between -85 and 85 or app_found_nearby.lng not between -180 and 180 then
    raise exception 'bad_location' using errcode = 'P0001';
  end if;
  v_here := extensions.st_setsrid(extensions.st_makepoint(app_found_nearby.lng, app_found_nearby.lat), 4326)::extensions.geography;

  return coalesce((
    select jsonb_agg(x.j order by x.starts_at, x.dist)
    from (
      select public.drop_to_json(d) || jsonb_build_object(
               'distance', round(m.dist::numeric, 1),
               'captured', me is not null and exists (
                 select 1 from public.inventory i where i.drop_id = d.id and i.captured_by = me and i.source = 'capture'),
               'mine', d.owner_id = me) as j,
             e.starts_at, m.dist
      from public.drops d
      join public.found_events e on e.id = d.found_event_id
      cross join lateral (select extensions.st_distance(d.geom::extensions.geography, v_here) as dist) m
      where extensions.st_dwithin(d.geom::extensions.geography, v_here, v_radius)
        and public.drop_on_map(d)
      order by e.starts_at, m.dist
      limit 150) x), '[]'::jsonb);
end;
$$;

revoke execute on function public.app_found_nearby(double precision, double precision, integer) from public;
grant execute on function public.app_found_nearby(double precision, double precision, integer) to anon, authenticated;
