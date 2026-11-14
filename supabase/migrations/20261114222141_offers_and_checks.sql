-- Hololoco, part 5: offers, rarity, quests, and the automatic check.
--
-- Businesses can now add offers: what people get, how many there are, how many
-- each person can claim, and the terms. The business says how rare the offer is
-- (common, uncommon or rare), which decides how it looks in the app, how often
-- people come across it, and which stage of a quest it can be in; and whether it
-- can be part of quests at all.
--
-- Every drop someone adds, and every change to what it says, looks like or where
-- it is, now gets an automatic check: the check-drop Edge Function asks Claude.
-- The check approves the drop or holds it for a person, saying why. It never
-- turns a drop down by itself. For offers it also suggests a rarity, and for
-- any drop it can give a tip on placing it.
--
-- The check can't approve a drop whose photo or model a person hasn't approved,
-- one with an open report, or one a person turned down before. Staff drops skip it.
--
-- Who can do what:
--   * Owners write their offers' public fields; never `claimed`, and nothing
--     about the check.
--   * Only the private.* functions below record a check, and the API can't reach
--     them: the Edge Function calls them over a direct database connection.
--
-- Set up once per project, outside this migration (the address isn't in the repo):
--   select vault.create_secret('https://<project-ref>.supabase.co', 'project_url');
-- Then deploy supabase/functions/check-drop and give it an ANTHROPIC_API_KEY secret.

create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron;

-- ---------------------------------------------------------------------------
-- Offers
-- ---------------------------------------------------------------------------

alter table public.drops drop constraint drops_type_check;
alter table public.drops add constraint drops_type_check check (type in ('object', 'message', 'offer'));

create table public.offers (
  drop_id text primary key references public.drops (id) on delete cascade,
  -- What people get, shown as written: "Buy one coffee, get one free".
  savings text not null check (char_length(btrim(savings)) between 1 and 60),
  terms text not null default '' check (char_length(terms) <= 300),
  -- How many there are in all, and how many one person can claim.
  quantity integer not null default 100 check (quantity between 1 and 10000),
  per_person smallint not null default 1 check (per_person between 1 and 10),
  -- Set by claims in the app (later). Owners can't write it.
  claimed integer not null default 0 check (claimed >= 0),
  rarity text not null default 'common' check (rarity in ('common', 'uncommon', 'rare')),
  in_quests boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.offers enable row level security;

create policy "Owners read their offers" on public.offers
  for select to authenticated
  using (exists (select 1 from public.drops d where d.id = drop_id and d.owner_id = (select auth.uid())));

create policy "Owners add offers" on public.offers
  for insert to authenticated
  with check (exists (select 1 from public.drops d where d.id = drop_id and d.owner_id = (select auth.uid())));

create policy "Owners change their offers" on public.offers
  for update to authenticated
  using (exists (select 1 from public.drops d where d.id = drop_id and d.owner_id = (select auth.uid())))
  with check (exists (select 1 from public.drops d where d.id = drop_id and d.owner_id = (select auth.uid())));

create policy "Owners remove their offers" on public.offers
  for delete to authenticated
  using (exists (select 1 from public.drops d where d.id = drop_id and d.owner_id = (select auth.uid())));

revoke all on table public.offers from anon, authenticated;
grant select, delete on table public.offers to authenticated;
grant insert (drop_id, savings, terms, quantity, per_person, rarity, in_quests) on table public.offers to authenticated;
grant update (savings, terms, quantity, per_person, rarity, in_quests) on table public.offers to authenticated;

-- ---------------------------------------------------------------------------
-- The automatic check
-- ---------------------------------------------------------------------------

-- Where each drop is in its check. Null for drops that never needed one (staff's,
-- and drops from before this migration).
--   queued:  waiting for the Edge Function to pick it up
--   running: the Edge Function is checking it now (check_run is the attempt)
--   retry:   the last attempt failed; the retry job tries again in a minute
--   done:    finished, approved or held for a person
--   failed:  gave up after three attempts, or the check isn't set up: a person checks it
alter table public.drops
  add column check_state text check (check_state in ('queued', 'running', 'retry', 'done', 'failed')),
  add column check_run bigint,
  add column check_attempts smallint not null default 0,
  add column check_at timestamptz;

create index drops_check_state_idx on public.drops (check_state, check_at)
  where check_state in ('queued', 'running', 'retry');

-- Every attempt and what it said. Kept after its drop is deleted, like the
-- moderation log, so the daily limit still counts it.
create table public.drop_checks (
  id bigint generated always as identity primary key,
  drop_id text not null,
  owner_id uuid references public.profiles (id) on delete cascade,
  status text not null default 'running' check (status in ('running', 'done', 'failed')),
  -- What the check said, and what happened: it can't approve some drops, and a
  -- result for a drop that changed in the meantime is ignored.
  decision text check (decision in ('approve', 'hold')),
  applied text check (applied in ('approve', 'hold', 'ignored')),
  model text,
  -- For staff.
  reason text,
  concerns jsonb not null default '[]'::jsonb,
  -- For the owner.
  owner_note text,
  suggested_rarity text check (suggested_rarity in ('common', 'uncommon', 'rare')),
  rarity_reason text,
  placement_tip text,
  error text,
  input_tokens integer,
  output_tokens integer,
  created_at timestamptz not null default now(),
  finished_at timestamptz
);

create index drop_checks_drop_idx on public.drop_checks (drop_id, id desc);
create index drop_checks_owner_idx on public.drop_checks (owner_id, created_at desc);

-- No policies and no grants: read through my_drops and the review queue only.
alter table public.drop_checks enable row level security;
revoke all on table public.drop_checks from anon, authenticated;

-- Approvals by the check go in the moderation log too, with no person as the actor.
alter table public.moderation_events add column automatic boolean not null default false;

-- ---------------------------------------------------------------------------
-- The write rules, now queueing the check.
-- ---------------------------------------------------------------------------

create or replace function public.drops_before_write()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
  staff boolean := public.is_staff();
  profile public.profiles;
  asset public.assets;
  check_crowding boolean;
  needs_check boolean := false;
begin
  -- No signed-in user means the service role or the SQL editor, and
  -- hololoco.system means one of the database's own functions: both trusted.
  if me is null or coalesce(current_setting('hololoco.system', true), '') = 'on' then
    new.updated_at := now();
    return new;
  end if;

  if tg_op = 'INSERT' then
    new.owner_id := me;
    new.created_at := now();
    new.paused := false;
    new.review_reason := null;

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

    -- Staff drops go straight on; everyone else's wait for the automatic check.
    if staff then
      new.review := 'approved';
    else
      new.review := 'pending';
      needs_check := true;
    end if;
  else
    if new.id <> old.id or new.owner_id <> old.owner_id or new.created_at <> old.created_at then
      raise exception 'not_allowed' using errcode = 'P0001';
    end if;
    if not staff and (new.review <> old.review
                      or new.review_reason is distinct from old.review_reason
                      or new.check_state is distinct from old.check_state
                      or new.check_run is distinct from old.check_run
                      or new.check_attempts <> old.check_attempts
                      or new.check_at is distinct from old.check_at) then
      raise exception 'not_allowed' using errcode = 'P0001';
    end if;
    -- Changing what it says, what it looks like or where it is, or editing one
    -- that wasn't approved, sends it back for the check.
    if not staff and (old.review = 'rejected'
                      or new.type <> old.type
                      or new.title <> old.title
                      or new.description <> old.description
                      or new.object_id is distinct from old.object_id
                      or new.asset_id is distinct from old.asset_id
                      or new.lat <> old.lat
                      or new.lng <> old.lng) then
      new.review := 'pending';
      new.review_reason := null;
      needs_check := true;
    end if;
  end if;

  -- An upload must be the person's own and not turned down, and a drop that
  -- uses one waits for review until the upload is approved, staff included.
  if new.asset_id is not null and (tg_op = 'INSERT' or new.asset_id is distinct from old.asset_id) then
    select * into asset from public.assets a where a.id = new.asset_id;
    if asset.id is null or asset.owner_id <> me then
      raise exception 'asset_not_found' using errcode = 'P0001';
    end if;
    if asset.status = 'rejected' then
      raise exception 'asset_rejected' using errcode = 'P0001';
    end if;
    if asset.status <> 'approved' then
      new.review := 'pending';
      new.review_reason := null;
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

  if needs_check then
    new.check_state := 'queued';
    new.check_at := now();
    new.check_attempts := 0;
  end if;

  new.updated_at := now();
  return new;
end;
$$;

-- Changing what an offer gives, its terms or its rarity sends its drop back for
-- the check too. (A new offer's drop is already queued.)
create function public.offers_before_write()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    new.claimed := 0;
    new.created_at := now();
  elsif new.drop_id <> old.drop_id then
    raise exception 'not_allowed' using errcode = 'P0001';
  end if;
  new.updated_at := now();

  if tg_op = 'UPDATE'
     and auth.uid() is not null
     and coalesce(current_setting('hololoco.system', true), '') <> 'on'
     and not public.is_staff()
     and (new.savings <> old.savings or new.terms <> old.terms or new.rarity <> old.rarity) then
    perform set_config('hololoco.system', 'on', true);
    update public.drops d set
      review = 'pending', review_reason = null,
      check_state = 'queued', check_at = now(), check_attempts = 0
    where d.id = new.drop_id and d.check_state is distinct from 'queued';
    perform set_config('hololoco.system', '', true);
  end if;
  return new;
end;
$$;

revoke execute on function public.offers_before_write() from public, anon, authenticated;

create trigger offers_before_write
  before insert or update on public.offers
  for each row execute function public.offers_before_write();

-- ---------------------------------------------------------------------------
-- Asking the Edge Function to check a drop, and trying again when it fails.
-- ---------------------------------------------------------------------------

-- Fire and forget: pg_net sends the request once this transaction commits. A
-- problem here must never stop a drop being saved, so it only warns; the retry
-- job sends it again.
create function private.send_check(p_drop text)
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
    url := rtrim(v_url, '/') || '/functions/v1/check-drop',
    body := jsonb_build_object('dropId', p_drop),
    headers := jsonb_build_object('Content-Type', 'application/json'),
    timeout_milliseconds := 10000);
exception when others then
  raise warning 'send_check(%): %', p_drop, sqlerrm;
end;
$$;

revoke execute on function private.send_check(text) from public, anon, authenticated;

create function public.drops_request_check()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.send_check(new.id);
  return null;
end;
$$;

revoke execute on function public.drops_request_check() from public, anon, authenticated;

create trigger drops_check_on_insert
  after insert on public.drops
  for each row when (new.check_state = 'queued')
  execute function public.drops_request_check();

create trigger drops_check_on_update
  after update on public.drops
  for each row when (new.check_state = 'queued'
                     and (old.check_state is distinct from 'queued' or new.check_at is distinct from old.check_at))
  execute function public.drops_request_check();

-- Every minute: send again what's been queued too long, retry what failed, and
-- after three attempts give up so a person checks it.
create function private.retry_checks()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform set_config('hololoco.system', 'on', true);

  update public.drop_checks c set status = 'failed', error = 'timed_out', applied = 'hold', finished_at = now()
  where c.status = 'running' and c.created_at < now() - interval '5 minutes';

  -- A request nobody claimed counts as an attempt too, so a check that can't be
  -- reached at all still ends with a person.
  update public.drops d set
    check_state = case when d.check_attempts >= 3 then 'failed' else 'queued' end,
    check_attempts = case when d.check_state = 'queued' then d.check_attempts + 1 else d.check_attempts end,
    check_at = now()
  where (d.check_state = 'queued' and d.check_at < now() - interval '2 minutes')
     or (d.check_state = 'running' and d.check_at < now() - interval '5 minutes')
     or (d.check_state = 'retry' and d.check_at < now() - interval '1 minute');

  perform set_config('hololoco.system', '', true);
end;
$$;

revoke execute on function private.retry_checks() from public, anon, authenticated;

select cron.schedule('retry-drop-checks', '* * * * *', 'select private.retry_checks()');

-- ---------------------------------------------------------------------------
-- What the Edge Function calls. Each one is safe to call twice: only one call
-- can claim a queued drop, and a result only counts for the attempt it belongs to.
-- ---------------------------------------------------------------------------

-- Claim a queued drop and return everything the check needs, or null if it isn't
-- waiting (already claimed, changed, deleted or decided).
create function private.claim_check(p_drop text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  d public.drops;
  v_run bigint;
begin
  select * into d from public.drops x where x.id = p_drop and x.check_state = 'queued' for update skip locked;
  if d.id is null then
    return null;
  end if;

  perform set_config('hololoco.system', 'on', true);

  -- At most 40 checks a day per account; past that a person checks the rest.
  if (select count(*) from public.drop_checks c
      where c.owner_id = d.owner_id and c.created_at > now() - interval '1 day') >= 40 then
    insert into public.drop_checks (drop_id, owner_id, status, applied, error, finished_at)
    values (d.id, d.owner_id, 'failed', 'hold', 'daily_limit', now());
    update public.drops x set check_state = 'failed', check_at = now() where x.id = d.id;
    perform set_config('hololoco.system', '', true);
    return null;
  end if;

  insert into public.drop_checks (drop_id, owner_id) values (d.id, d.owner_id) returning id into v_run;
  update public.drops x set
    check_state = 'running', check_run = v_run, check_attempts = x.check_attempts + 1, check_at = now()
  where x.id = d.id
  returning x.* into d;
  perform set_config('hololoco.system', '', true);

  return jsonb_build_object(
    'runId', v_run,
    'drop', public.drop_to_json(d),
    'lookName', (select o.name from public.library_objects o where o.id = d.object_id),
    'owner', (select jsonb_build_object(
                'accountAgeDays', extract(day from now() - p.created_at)::integer,
                'approvedDrops', (select count(*) from public.drops x where x.owner_id = d.owner_id and x.review = 'approved'),
                'notApprovedDrops', (select count(*) from public.drops x where x.owner_id = d.owner_id and x.review = 'rejected'))
              from public.profiles p where p.id = d.owner_id),
    'approvedDropsWithin100m', (select count(*) from public.drops x
                                where x.id <> d.id and x.review = 'approved' and not x.paused
                                  and extensions.st_dwithin(
                                        x.geom::extensions.geography, d.geom::extensions.geography, 100)),
    'turnedDownByAPersonBefore', exists (select 1 from public.moderation_events e
                                         where e.drop_id = d.id and e.action = 'reject' and not e.automatic));
end;
$$;

-- Record what the check said and act on it. Returns what happened: approve, hold or ignored.
create function private.finish_check(p_run bigint, p_result jsonb)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  c public.drop_checks;
  d public.drops;
  v_decision text := case when p_result ->> 'decision' = 'approve' then 'approve' else 'hold' end;
  v_applied text;
  v_rarity text := p_result ->> 'suggestedRarity';
  v_concerns jsonb := p_result -> 'concerns';
begin
  select * into c from public.drop_checks x where x.id = p_run for update;
  if c.id is null or c.status <> 'running' then
    return 'ignored';
  end if;

  select * into d from public.drops x where x.id = c.drop_id for update;
  if d.id is null or d.check_run is distinct from p_run or d.check_state <> 'running' then
    v_applied := 'ignored';
  elsif v_decision = 'approve' and (
          exists (select 1 from public.assets a where a.id = d.asset_id and a.status <> 'approved')
          or exists (select 1 from public.reports r where r.drop_id = d.id and r.status = 'open')
          or exists (select 1 from public.moderation_events e
                     where e.drop_id = d.id and e.action = 'reject' and not e.automatic)) then
    v_applied := 'hold';
  else
    v_applied := v_decision;
  end if;

  if v_concerns is null or jsonb_typeof(v_concerns) <> 'array' then
    v_concerns := '[]'::jsonb;
  end if;

  update public.drop_checks x set
    status = 'done',
    decision = v_decision,
    applied = v_applied,
    model = left(p_result ->> 'model', 60),
    reason = left(nullif(btrim(p_result ->> 'reason'), ''), 1000),
    concerns = v_concerns,
    owner_note = left(nullif(btrim(p_result ->> 'ownerNote'), ''), 400),
    suggested_rarity = case when v_rarity in ('common', 'uncommon', 'rare') then v_rarity end,
    rarity_reason = left(nullif(btrim(p_result ->> 'rarityReason'), ''), 300),
    placement_tip = left(nullif(btrim(p_result ->> 'placementTip'), ''), 300),
    input_tokens = (p_result ->> 'inputTokens')::integer,
    output_tokens = (p_result ->> 'outputTokens')::integer,
    finished_at = now()
  where x.id = p_run;

  if v_applied = 'ignored' then
    return v_applied;
  end if;

  perform set_config('hololoco.system', 'on', true);
  update public.drops x set
    check_state = 'done',
    check_at = now(),
    review = case when v_applied = 'approve' then 'approved' else x.review end
  where x.id = d.id;
  perform set_config('hololoco.system', '', true);

  if v_applied = 'approve' then
    insert into public.moderation_events (drop_id, drop_title, actor_id, action, reason, automatic)
    values (d.id, d.title, null, 'approve', null, true);
  end if;
  return v_applied;
end;
$$;

-- Record a failed attempt. A final failure (the check isn't set up) or the third
-- attempt hands the drop to a person; otherwise the retry job tries again.
create function private.fail_check(p_run bigint, p_error text, p_final boolean default false)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_drop text;
begin
  update public.drop_checks x set status = 'failed', applied = 'hold', error = left(p_error, 300), finished_at = now()
  where x.id = p_run and x.status = 'running'
  returning x.drop_id into v_drop;
  if v_drop is null then
    return;
  end if;

  perform set_config('hololoco.system', 'on', true);
  update public.drops x set
    check_state = case when p_final or x.check_attempts >= 3 then 'failed' else 'retry' end,
    check_at = now()
  where x.id = v_drop and x.check_run = p_run and x.check_state = 'running';
  perform set_config('hololoco.system', '', true);
end;
$$;

revoke execute on function private.claim_check(text) from public, anon, authenticated;
revoke execute on function private.finish_check(bigint, jsonb) from public, anon, authenticated;
revoke execute on function private.fail_check(bigint, text, boolean) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Saving a drop, now with its offer.
-- ---------------------------------------------------------------------------

create or replace function public.save_drop(payload jsonb)
returns text
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_id text := nullif(payload ->> 'id', '');
  v_type text := payload ->> 'type';
  v_tz text := payload ->> 'timeZone';
  v_timing text := payload -> 'timing' ->> 'kind';
  v_blocks jsonb := payload -> 'timing' -> 'blocks';
  v_object text := nullif(payload ->> 'objectId', '');
  v_asset uuid := nullif(payload ->> 'assetId', '')::uuid;
  v_offer jsonb := payload -> 'offer';
  v_start timestamptz;
  v_end timestamptz;
begin
  if not public.is_time_zone(v_tz) then
    raise exception 'bad_time_zone' using errcode = 'P0001';
  end if;
  if v_type = 'offer' and (v_offer is null or jsonb_typeof(v_offer) <> 'object'
                           or nullif(btrim(v_offer ->> 'savings'), '') is null) then
    raise exception 'offer_incomplete' using errcode = 'P0001';
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
    insert into public.drops (type, title, description, object_id, asset_id, lat, lng, height, size, turn,
                              time_zone, timing, starts_at, ends_at, audience)
    values (v_type, btrim(payload ->> 'title'), btrim(coalesce(payload ->> 'description', '')),
            v_object, v_asset,
            (payload -> 'placement' ->> 'lat')::double precision,
            (payload -> 'placement' ->> 'lng')::double precision,
            (payload -> 'placement' ->> 'height')::real,
            (payload -> 'placement' ->> 'size')::real,
            (payload -> 'placement' ->> 'turn')::real,
            v_tz, v_timing, v_start, v_end, payload ->> 'audience')
    returning id into v_id;
  else
    update public.drops set
      type = v_type,
      title = btrim(payload ->> 'title'),
      description = btrim(coalesce(payload ->> 'description', '')),
      object_id = v_object,
      asset_id = v_asset,
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

  if v_type = 'offer' then
    update public.offers set
      savings = btrim(v_offer ->> 'savings'),
      terms = btrim(coalesce(v_offer ->> 'terms', '')),
      quantity = (v_offer ->> 'quantity')::integer,
      per_person = (v_offer ->> 'perPerson')::smallint,
      rarity = coalesce(v_offer ->> 'rarity', 'common'),
      in_quests = coalesce((v_offer ->> 'inQuests')::boolean, false)
    where drop_id = v_id;
    if not found then
      insert into public.offers (drop_id, savings, terms, quantity, per_person, rarity, in_quests)
      values (v_id, btrim(v_offer ->> 'savings'), btrim(coalesce(v_offer ->> 'terms', '')),
              (v_offer ->> 'quantity')::integer, (v_offer ->> 'perPerson')::smallint,
              coalesce(v_offer ->> 'rarity', 'common'), coalesce((v_offer ->> 'inQuests')::boolean, false));
    end if;
  else
    delete from public.offers where drop_id = v_id;
  end if;

  return v_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- Reading drops: now with the offer, and the check for owners and staff.
-- ---------------------------------------------------------------------------

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
                'rarity', o.rarity, 'inQuests', o.in_quests)
              from public.offers o where o.drop_id = d.id and d.type = 'offer'),
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

-- The check as the owner sees it, or with staff's notes too. While a check is
-- still going, only its state.
create function public.drop_check_json(d public.drops, for_staff boolean)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when d.check_state is null then null
    when d.check_state in ('queued', 'running', 'retry') then jsonb_build_object('state', d.check_state)
    else jsonb_build_object('state', d.check_state) || coalesce((
      select jsonb_strip_nulls(jsonb_build_object(
          'applied', c.applied,
          'ownerNote', c.owner_note,
          'suggestedRarity', c.suggested_rarity,
          'rarityReason', c.rarity_reason,
          'placementTip', c.placement_tip,
          'at', c.finished_at))
        || case when for_staff then jsonb_strip_nulls(jsonb_build_object(
          'decision', c.decision,
          'reason', c.reason,
          'concerns', c.concerns,
          'error', c.error,
          'model', c.model)) else '{}'::jsonb end
      from public.drop_checks c
      where c.drop_id = d.id and c.status <> 'running'
      order by c.id desc
      limit 1), '{}'::jsonb)
  end;
$$;

revoke execute on function public.drop_check_json(public.drops, boolean) from public, anon, authenticated;

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
    'check', public.drop_check_json(d, false))
  from public.drops d
  where d.owner_id = (select auth.uid())
  order by d.created_at desc;
$$;

-- Drops still being checked aren't waiting for a person yet.
create or replace function public.review_queue()
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
    select public.drop_to_json(d) || jsonb_build_object(
      'ownerApproved', (select count(*) from public.drops x where x.owner_id = d.owner_id and x.review = 'approved'),
      'ownerRejected', (select count(*) from public.drops x where x.owner_id = d.owner_id and x.review = 'rejected'),
      'ownerSince', (select p.created_at from public.profiles p where p.id = d.owner_id),
      'assetFiles', public.drop_asset_files(d),
      'check', public.drop_check_json(d, true))
    from public.drops d
    where d.review = 'pending'
      and d.check_state is distinct from 'queued'
      and d.check_state is distinct from 'running'
      and d.check_state is distinct from 'retry'
      and not exists (select 1 from public.reports r where r.drop_id = d.id and r.status = 'open')
    order by d.created_at asc
    limit 200;
end;
$$;

-- A person's decision ends any check still going, so a late result can't undo it.
create or replace function public.review_drop(drop_id text, decision text, reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_drop public.drops;
  v_reason text := nullif(btrim(review_drop.reason), '');
  v_asset public.assets;
begin
  if not public.is_staff() then
    raise exception 'not_staff' using errcode = 'P0001';
  end if;
  if review_drop.decision not in ('approve', 'reject', 'reopen') then
    raise exception 'bad_decision' using errcode = 'P0001';
  end if;
  if review_drop.decision = 'reject' and v_reason is null then
    raise exception 'reason_needed' using errcode = 'P0001';
  end if;

  select a.* into v_asset
  from public.drops d join public.assets a on a.id = d.asset_id
  where d.id = review_drop.drop_id;
  if review_drop.decision = 'approve' and v_asset.id is not null and v_asset.status <> 'approved' then
    raise exception 'asset_not_published' using errcode = 'P0001';
  end if;

  update public.drops d set
    review = case review_drop.decision when 'approve' then 'approved' when 'reject' then 'rejected' else 'pending' end,
    review_reason = case when review_drop.decision = 'reject' then v_reason end,
    check_state = case when d.check_state in ('queued', 'running', 'retry') then 'done' else d.check_state end
  where d.id = review_drop.drop_id
  returning d.* into v_drop;

  if v_drop.id is null then
    raise exception 'not_found' using errcode = 'P0001';
  end if;

  if v_asset.id is not null and review_drop.decision = 'reject' then
    update public.assets a set status = 'rejected', public_model_path = null,
      public_thumbnail_path = null, public_photo_path = null
    where a.id = v_asset.id;
  elsif v_asset.id is not null and review_drop.decision = 'reopen' and v_asset.status = 'rejected' then
    update public.assets a set status = 'pending' where a.id = v_asset.id;
  end if;

  insert into public.moderation_events (drop_id, drop_title, actor_id, action, reason)
  values (v_drop.id, v_drop.title, auth.uid(), review_drop.decision, v_reason);

  if review_drop.decision in ('approve', 'reject') then
    update public.reports r set
      status = case review_drop.decision when 'approve' then 'dismissed' else 'resolved' end,
      resolution = v_reason,
      resolved_by = auth.uid(),
      resolved_at = now()
    where r.drop_id = v_drop.id and r.status = 'open';
  end if;

  return public.drop_to_json(v_drop);
end;
$$;

-- The log now says when the automatic check approved something.
create or replace function public.review_history(max_results integer default 30)
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
    select jsonb_build_object(
      'id', e.id,
      'dropId', e.drop_id,
      'title', e.drop_title,
      'action', e.action,
      'reason', e.reason,
      'at', e.created_at,
      'by', case when e.automatic then 'Automatic check' else coalesce(p.display_name, 'Staff') end,
      'automatic', e.automatic,
      'review', d.review)
    from public.moderation_events e
    left join public.profiles p on p.id = e.actor_id
    left join public.drops d on d.id = e.drop_id
    order by e.created_at desc, e.id desc
    limit least(greatest(max_results, 1), 100);
end;
$$;
