-- Hololoco, part 1: people and drops (Phase 2).
--
-- The database enforces every rule in this file. The app checks the same rules
-- first only so it can explain them in plain words.
--
-- Who can do what:
--   * Visitors (anon) read public drops only through the public_* functions.
--     They can't read any table directly.
--   * Signed-in people read, edit, pause and delete only their own drops and
--     their own profile. They can't change a drop's review status, its owner,
--     or their own staff flag.
--   * An account's drops are reviewed until one of them has been approved.
--   * Limits (from lib/drops/limits.ts): 10 drops at a time, 5 new a day,
--     20 public drops within 100 m, 30 m size, 100 m height. Staff are exempt.
--
-- Offers, uploads, reports and the review queue come in later migrations.

create extension if not exists postgis with schema extensions;

-- ---------------------------------------------------------------------------
-- Profiles: one per account, created when the account is.
-- ---------------------------------------------------------------------------

create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  -- Shown on the person's drops. Required before their first publish.
  display_name text check (display_name is null or char_length(btrim(display_name)) between 1 and 40),
  kind text not null default 'individual' check (kind in ('individual', 'business')),
  is_staff boolean not null default false,
  -- When they confirmed they're 18 or older. Required before their first publish.
  adult_confirmed_at timestamptz,
  created_at timestamptz not null default now()
);

alter table public.profiles enable row level security;

create policy "People read their own profile" on public.profiles
  for select to authenticated using (id = (select auth.uid()));

create policy "People update their own profile" on public.profiles
  for update to authenticated
  using (id = (select auth.uid()))
  with check (id = (select auth.uid()));

revoke all on table public.profiles from anon, authenticated;
grant select on table public.profiles to authenticated;
-- Only these two columns. kind and is_staff are set by staff.
grant update (display_name, adult_confirmed_at) on table public.profiles to authenticated;

create function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id) values (new.id);
  return new;
end;
$$;

revoke execute on function public.handle_new_user() from public, anon, authenticated;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Accounts that existed before this migration get a profile too.
insert into public.profiles (id) select id from auth.users on conflict (id) do nothing;

create function public.is_staff()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((select p.is_staff from public.profiles p where p.id = (select auth.uid())), false);
$$;

-- ---------------------------------------------------------------------------
-- Ready-made objects. The files live in public/library/; this list is what a
-- drop is allowed to point at. Later migrations add photos and GLB uploads.
-- ---------------------------------------------------------------------------

create table public.library_objects (
  id text primary key check (id ~ '^[a-z0-9-]{1,40}$'),
  name text not null,
  active boolean not null default true
);

alter table public.library_objects enable row level security;

create policy "Anyone reads the library" on public.library_objects
  for select to anon, authenticated using (true);

revoke all on table public.library_objects from anon, authenticated;
grant select on table public.library_objects to anon, authenticated;

insert into public.library_objects (id, name) values
  ('pizza', 'Pizza slice'),
  ('cup', 'Coffee cup'),
  ('gift', 'Gift box'),
  ('star', 'Star'),
  ('heart', 'Heart'),
  ('note', 'Speech bubble');

-- ---------------------------------------------------------------------------
-- Drops
-- ---------------------------------------------------------------------------

-- Short ids for share links, e.g. "k7p2m9qa". Link-only drops rely on them
-- being unguessable, so they come from gen_random_uuid's random bytes.
create function public.new_drop_id()
returns text
language sql
volatile
set search_path = ''
as $$
  select string_agg(
    substr('abcdefghjkmnpqrstuvwxyz23456789', 1 + get_byte(b.bytes, i) % 31, 1), ''
  )
  from (select decode(replace(gen_random_uuid()::text, '-', ''), 'hex') as bytes) b,
       generate_series(0, 7) i;
$$;

create function public.is_time_zone(tz text)
returns boolean
language plpgsql
stable
set search_path = ''
as $$
begin
  perform now() at time zone tz;
  return true;
exception when others then
  return false;
end;
$$;

create table public.drops (
  id text primary key default public.new_drop_id(),
  owner_id uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  -- 'offer' arrives with business verification.
  type text not null check (type in ('object', 'message')),
  title text not null check (char_length(btrim(title)) between 1 and 70),
  description text not null default '' check (char_length(description) <= 400),
  object_id text not null references public.library_objects (id),

  lat double precision not null check (lat between -85 and 85),
  lng double precision not null check (lng between -180 and 180),
  -- Metres above ground, metres across, degrees clockwise from north.
  height real not null default 0 check (height between 0 and 100),
  size real not null default 4 check (size >= 0.5 and size <= 30),
  turn real not null default 0 check (turn >= 0 and turn < 360),
  geom extensions.geometry(Point, 4326)
    generated always as (extensions.st_setsrid(extensions.st_makepoint(lng, lat), 4326)) stored,

  -- Schedules use the drop's own zone, never the viewer's.
  time_zone text not null check (public.is_time_zone(time_zone)),
  timing text not null default 'always' check (timing in ('always', 'once', 'weekly')),
  starts_at timestamptz,
  ends_at timestamptz,
  audience text not null default 'everyone' check (audience in ('everyone', 'link')),

  -- Set by the database on insert, then only by staff.
  review text not null default 'pending' check (review in ('pending', 'approved', 'rejected')),
  -- Set by the owner.
  paused boolean not null default false,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint once_has_both_times check ((timing = 'once') = (starts_at is not null and ends_at is not null)),
  constraint once_ends_after_start check (ends_at is null or ends_at > starts_at)
);

create index drops_geom_idx on public.drops using gist (geom);
create index drops_owner_idx on public.drops (owner_id, created_at desc);

alter table public.drops enable row level security;

create policy "Owners read their drops" on public.drops
  for select to authenticated using (owner_id = (select auth.uid()));

create policy "Owners add drops" on public.drops
  for insert to authenticated with check (owner_id = (select auth.uid()));

create policy "Owners change their drops" on public.drops
  for update to authenticated
  using (owner_id = (select auth.uid()))
  with check (owner_id = (select auth.uid()));

create policy "Owners delete their drops" on public.drops
  for delete to authenticated using (owner_id = (select auth.uid()));

revoke all on table public.drops from anon, authenticated;
grant select, delete on table public.drops to authenticated;
grant insert (type, title, description, object_id, lat, lng, height, size, turn,
              time_zone, timing, starts_at, ends_at, audience)
  on table public.drops to authenticated;
grant update (type, title, description, object_id, lat, lng, height, size, turn,
              time_zone, timing, starts_at, ends_at, audience, paused)
  on table public.drops to authenticated;

-- Weekly hours. Each block lists its days (0 = Sunday … 6 = Saturday) and
-- ends after it starts on the same day.
create table public.schedule_blocks (
  id bigint generated always as identity primary key,
  drop_id text not null references public.drops (id) on delete cascade,
  days smallint[] not null
    check (cardinality(days) between 1 and 7 and days <@ array[0, 1, 2, 3, 4, 5, 6]::smallint[]),
  start_time time not null,
  end_time time not null,
  constraint ends_after_start check (end_time > start_time)
);

create index schedule_blocks_drop_idx on public.schedule_blocks (drop_id);

alter table public.schedule_blocks enable row level security;

create policy "Owners read their hours" on public.schedule_blocks
  for select to authenticated
  using (exists (select 1 from public.drops d where d.id = drop_id and d.owner_id = (select auth.uid())));

create policy "Owners add hours" on public.schedule_blocks
  for insert to authenticated
  with check (exists (select 1 from public.drops d where d.id = drop_id and d.owner_id = (select auth.uid())));

create policy "Owners remove hours" on public.schedule_blocks
  for delete to authenticated
  using (exists (select 1 from public.drops d where d.id = drop_id and d.owner_id = (select auth.uid())));

revoke all on table public.schedule_blocks from anon, authenticated;
grant select, delete on table public.schedule_blocks to authenticated;
grant insert (drop_id, days, start_time, end_time) on table public.schedule_blocks to authenticated;

-- ---------------------------------------------------------------------------
-- The rules on every write. Errors carry a short code the app turns into words.
-- ---------------------------------------------------------------------------

create function public.drops_before_write()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
  staff boolean := public.is_staff();
  profile public.profiles;
  check_crowding boolean;
begin
  -- No signed-in user means the service role or the SQL editor: trusted.
  if me is null then
    new.updated_at := now();
    return new;
  end if;

  if tg_op = 'INSERT' then
    new.owner_id := me;
    new.created_at := now();
    new.paused := false;

    select * into profile from public.profiles where id = me;
    if profile.display_name is null or profile.adult_confirmed_at is null then
      raise exception 'profile_incomplete' using errcode = 'P0001';
    end if;

    if not staff then
      if (select count(*) from public.drops d where d.owner_id = me and d.review <> 'rejected') >= 10 then
        raise exception 'limit_total' using errcode = 'P0001';
      end if;
      if (select count(*) from public.drops d
          where d.owner_id = me and d.created_at > now() - interval '1 day') >= 5 then
        raise exception 'limit_daily' using errcode = 'P0001';
      end if;
    end if;

    -- An account's drops are reviewed until one has been approved.
    new.review := case
      when staff or exists (select 1 from public.drops d where d.owner_id = me and d.review = 'approved')
        then 'approved'
      else 'pending'
    end;
  else
    if new.id <> old.id or new.owner_id <> old.owner_id or new.created_at <> old.created_at then
      raise exception 'not_allowed' using errcode = 'P0001';
    end if;
    if new.review <> old.review and not staff then
      raise exception 'not_allowed' using errcode = 'P0001';
    end if;
  end if;

  -- Crowding: only public drops count, and only when a public drop appears or moves.
  if tg_op = 'INSERT' then
    check_crowding := new.audience = 'everyone';
  else
    check_crowding := new.audience = 'everyone'
      and (new.lat <> old.lat or new.lng <> old.lng or old.audience <> 'everyone');
  end if;

  if check_crowding and not staff then
    if (select count(*) from public.drops d
        where d.id <> new.id
          and d.audience = 'everyone'
          and d.review = 'approved'
          and not d.paused
          and extensions.st_dwithin(
                d.geom::extensions.geography,
                extensions.st_setsrid(extensions.st_makepoint(new.lng, new.lat), 4326)::extensions.geography,
                100)) >= 20 then
      raise exception 'limit_crowded' using errcode = 'P0001';
    end if;
  end if;

  new.updated_at := now();
  return new;
end;
$$;

revoke execute on function public.drops_before_write() from public, anon, authenticated;

create trigger drops_before_write
  before insert or update on public.drops
  for each row execute function public.drops_before_write();

-- ---------------------------------------------------------------------------
-- Reading drops. Visitors only ever get drops through these functions, and
-- they return the shape the app uses (lib/drops/types.ts).
-- ---------------------------------------------------------------------------

-- Is the drop within its hours right now, in its own time zone?
create function public.drop_is_open(d public.drops)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select case d.timing
    when 'always' then true
    when 'once' then now() >= d.starts_at and now() < d.ends_at
    else exists (
      select 1 from public.schedule_blocks b
      where b.drop_id = d.id
        and extract(dow from now() at time zone d.time_zone)::smallint = any (b.days)
        and (now() at time zone d.time_zone)::time >= b.start_time
        and (now() at time zone d.time_zone)::time < b.end_time
    )
  end;
$$;

-- On the public map: approved, not paused, for everyone, and within its hours.
create function public.drop_on_map(d public.drops)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select d.review = 'approved' and not d.paused and d.audience = 'everyone' and public.drop_is_open(d);
$$;

create function public.drop_to_json(d public.drops)
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
    'paused', d.paused,
    'openNow', public.drop_is_open(d),
    'createdAt', d.created_at
  );
$$;

-- Helpers above take a whole row, so nobody may call them with a made-up one.
revoke execute on function public.drop_is_open(public.drops) from public, anon, authenticated;
revoke execute on function public.drop_on_map(public.drops) from public, anon, authenticated;
revoke execute on function public.drop_to_json(public.drops) from public, anon, authenticated;

-- Public drops inside the visible map area. This is the only place a map
-- position reaches the server, and it's the area being viewed, not the viewer's.
create function public.public_drops_in_bounds(
  west double precision,
  south double precision,
  east double precision,
  north double precision,
  max_results integer default 300
)
returns setof jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select public.drop_to_json(d)
  from public.drops d
  where extensions.st_intersects(d.geom, extensions.st_makeenvelope(west, south, east, north, 4326))
    and public.drop_on_map(d)
  order by d.created_at desc
  limit least(greatest(max_results, 1), 500);
$$;

-- One drop for its own page. Link-only drops are included, since having the
-- link is the point; paused and unapproved drops are not.
create function public.public_drop(drop_id text)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select public.drop_to_json(d)
  from public.drops d
  where d.id = drop_id and d.review = 'approved' and not d.paused;
$$;

-- Public drops whose words (title, who posted it, description, object) contain every search word.
create function public.search_public_drops(query text, max_results integer default 3)
returns setof jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select public.drop_to_json(d)
  from public.drops d
  left join public.profiles p on p.id = d.owner_id
  left join public.library_objects o on o.id = d.object_id
  where char_length(btrim(query)) between 1 and 100
    and public.drop_on_map(d)
    and not exists (
      select 1
      from regexp_split_to_table(lower(btrim(query)), '\s+') w
      where w <> ''
        and position(w in lower(concat_ws(' ', d.title, p.display_name, d.description, o.name))) = 0
    )
  order by d.created_at desc
  limit least(greatest(max_results, 1), 20);
$$;

-- The signed-in person's own drops, whatever their status.
create function public.my_drops()
returns setof jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select public.drop_to_json(d)
  from public.drops d
  where d.owner_id = (select auth.uid())
  order by d.created_at desc;
$$;

revoke execute on function public.my_drops() from public, anon;
grant execute on function public.public_drops_in_bounds(double precision, double precision, double precision, double precision, integer) to anon, authenticated;
grant execute on function public.public_drop(text) to anon, authenticated;
grant execute on function public.search_public_drops(text, integer) to anon, authenticated;
grant execute on function public.my_drops() to authenticated;

-- ---------------------------------------------------------------------------
-- Saving a drop and its hours together. Runs as the caller, so every policy,
-- grant and rule above still applies.
-- ---------------------------------------------------------------------------

create function public.save_drop(payload jsonb)
returns text
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_id text := nullif(payload ->> 'id', '');
  v_tz text := payload ->> 'timeZone';
  v_timing text := payload -> 'timing' ->> 'kind';
  v_blocks jsonb := payload -> 'timing' -> 'blocks';
  v_start timestamptz;
  v_end timestamptz;
begin
  if not public.is_time_zone(v_tz) then
    raise exception 'bad_time_zone' using errcode = 'P0001';
  end if;

  if v_timing = 'once' then
    -- Local wall-clock times in the drop's zone.
    v_start := ((payload -> 'timing' ->> 'start')::timestamp) at time zone v_tz;
    v_end := ((payload -> 'timing' ->> 'end')::timestamp) at time zone v_tz;
  elsif v_timing = 'weekly' then
    if jsonb_typeof(v_blocks) <> 'array' or jsonb_array_length(v_blocks) = 0 then
      raise exception 'schedule_empty' using errcode = 'P0001';
    end if;
    if jsonb_array_length(v_blocks) > 7 then
      raise exception 'schedule_too_long' using errcode = 'P0001';
    end if;
  end if;

  if v_id is null then
    insert into public.drops (type, title, description, object_id, lat, lng, height, size, turn,
                              time_zone, timing, starts_at, ends_at, audience)
    values (payload ->> 'type', btrim(payload ->> 'title'), btrim(coalesce(payload ->> 'description', '')),
            payload ->> 'objectId',
            (payload -> 'placement' ->> 'lat')::double precision,
            (payload -> 'placement' ->> 'lng')::double precision,
            (payload -> 'placement' ->> 'height')::real,
            (payload -> 'placement' ->> 'size')::real,
            (payload -> 'placement' ->> 'turn')::real,
            v_tz, v_timing, v_start, v_end, payload ->> 'audience')
    returning id into v_id;
  else
    update public.drops set
      type = payload ->> 'type',
      title = btrim(payload ->> 'title'),
      description = btrim(coalesce(payload ->> 'description', '')),
      object_id = payload ->> 'objectId',
      lat = (payload -> 'placement' ->> 'lat')::double precision,
      lng = (payload -> 'placement' ->> 'lng')::double precision,
      height = (payload -> 'placement' ->> 'height')::real,
      size = (payload -> 'placement' ->> 'size')::real,
      turn = (payload -> 'placement' ->> 'turn')::real,
      time_zone = v_tz,
      timing = v_timing,
      starts_at = v_start,
      ends_at = v_end,
      audience = payload ->> 'audience'
    where id = v_id
    returning id into v_id;

    if v_id is null then
      raise exception 'not_found' using errcode = 'P0001';
    end if;

    delete from public.schedule_blocks where drop_id = v_id;
  end if;

  if v_timing = 'weekly' then
    insert into public.schedule_blocks (drop_id, days, start_time, end_time)
    select v_id,
           array(select (x)::smallint from jsonb_array_elements_text(b -> 'days') x),
           (b ->> 'start')::time,
           (b ->> 'end')::time
    from jsonb_array_elements(v_blocks) b;
  end if;

  return v_id;
end;
$$;

revoke execute on function public.save_drop(jsonb) from public, anon;
grant execute on function public.save_drop(jsonb) to authenticated;
