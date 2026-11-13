-- Hololoco, part 3: reports (Phase 3).
--
-- Anyone can report a drop, with no account, and property owners can ask for a
-- drop to be removed. Only staff can read reports. A serious report (someone in
-- danger or something illegal, or someone's personal information) hides the
-- drop at once, and so do reports from three different people within a week:
-- the drop goes back to the review queue until a person decides.
--
-- People who report without an account are told apart by a keyed hash of their
-- connection that changes every week. Their address itself is never stored.

-- ---------------------------------------------------------------------------
-- A private schema the API can't reach, for the hashing key.
-- ---------------------------------------------------------------------------

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create table private.secrets (
  name text primary key,
  value text not null
);
insert into private.secrets (name, value)
values ('report_key', replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''))
on conflict (name) do nothing;

-- Who is reporting, as an opaque key: the account if signed in, otherwise the
-- connection's address mixed with a secret and the current week.
create function private.reporter_key()
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (select auth.uid())::text,
    md5(
      btrim(split_part(coalesce(nullif(current_setting('request.headers', true), '')::json ->> 'x-forwarded-for', ''), ',', 1))
      || '|' || to_char(now(), 'IYYY-IW')
      || '|' || (select s.value from private.secrets s where s.name = 'report_key')));
$$;

-- ---------------------------------------------------------------------------
-- Reports
-- ---------------------------------------------------------------------------

create table public.reports (
  id bigint generated always as identity primary key,
  -- Null for a removal request that isn't about one drop. Kept if the drop is deleted.
  drop_id text,
  drop_title text,
  reason text not null check (reason in ('offensive', 'spam', 'personal', 'unsafe', 'property', 'copyright', 'other')),
  details text check (details is null or char_length(details) <= 1000),
  -- So staff can reply. Only staff can read it.
  contact text check (contact is null or char_length(contact) <= 200),
  reporter_id uuid references public.profiles (id) on delete set null,
  reporter_key text not null,
  status text not null default 'open' check (status in ('open', 'resolved', 'dismissed')),
  resolution text check (resolution is null or char_length(resolution) <= 300),
  resolved_by uuid references public.profiles (id) on delete set null,
  resolved_at timestamptz,
  created_at timestamptz not null default now()
);

create index reports_open_drop_idx on public.reports (drop_id) where status = 'open';
create index reports_reporter_idx on public.reports (reporter_key, created_at desc);
create index reports_reporter_id_idx on public.reports (reporter_id);
create index reports_resolved_by_idx on public.reports (resolved_by);

-- No policies and no grants: reports are filed and read only through the functions below.
alter table public.reports enable row level security;
revoke all on table public.reports from anon, authenticated;

-- Automatic hiding is logged too, with no person as the actor.
alter table public.moderation_events drop constraint moderation_events_action_check;
alter table public.moderation_events
  add constraint moderation_events_action_check check (action in ('approve', 'reject', 'reopen', 'hide'));

-- ---------------------------------------------------------------------------
-- The write rules again, now letting the database itself hide a reported drop.
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
  check_crowding boolean;
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
    if not staff and (new.review <> old.review or new.review_reason is distinct from old.review_reason) then
      raise exception 'not_allowed' using errcode = 'P0001';
    end if;
    -- Editing a drop that wasn't approved sends it back for review.
    if not staff and old.review = 'rejected' then
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

  new.updated_at := now();
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- Filing a report. Anyone can, with or without an account.
-- ---------------------------------------------------------------------------

create function public.file_report(drop_id text, reason text, details text default null, contact text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_key text := private.reporter_key();
  v_details text := nullif(btrim(file_report.details), '');
  v_contact text := nullif(btrim(file_report.contact), '');
  v_drop public.drops;
  v_hide boolean := false;
begin
  if file_report.reason is null
     or file_report.reason not in ('offensive', 'spam', 'personal', 'unsafe', 'property', 'copyright', 'other') then
    raise exception 'bad_reason' using errcode = 'P0001';
  end if;
  if file_report.reason in ('other', 'property') and v_details is null then
    raise exception 'details_needed' using errcode = 'P0001';
  end if;
  if file_report.reason in ('property', 'copyright') and v_contact is null then
    raise exception 'contact_needed' using errcode = 'P0001';
  end if;

  if (select count(*) from public.reports r
      where r.reporter_key = v_key and r.created_at > now() - interval '1 day') >= 10 then
    raise exception 'limit_reports' using errcode = 'P0001';
  end if;

  -- A removal request that isn't about one drop.
  if nullif(file_report.drop_id, '') is null then
    if file_report.reason <> 'property' then
      raise exception 'not_found' using errcode = 'P0001';
    end if;
    insert into public.reports (drop_id, drop_title, reason, details, contact, reporter_id, reporter_key)
    values (null, null, 'property', v_details, v_contact, auth.uid(), v_key);
    return jsonb_build_object('filed', true, 'hidden', false);
  end if;

  -- Only drops a visitor can see can be reported.
  select * into v_drop from public.drops d
  where d.id = file_report.drop_id and d.review = 'approved' and not d.paused;
  if v_drop.id is null then
    raise exception 'not_found' using errcode = 'P0001';
  end if;

  -- One open report per person per drop; a repeat changes nothing.
  if exists (select 1 from public.reports r
             where r.drop_id = v_drop.id and r.reporter_key = v_key and r.status = 'open') then
    return jsonb_build_object('filed', true, 'hidden', false);
  end if;

  insert into public.reports (drop_id, drop_title, reason, details, contact, reporter_id, reporter_key)
  values (v_drop.id, v_drop.title, file_report.reason, v_details, v_contact, auth.uid(), v_key);

  -- Serious, or reported by three different people this week: hide it until a person looks.
  v_hide := file_report.reason in ('unsafe', 'personal')
    or (select count(distinct r.reporter_key) from public.reports r
        where r.drop_id = v_drop.id and r.status = 'open' and r.created_at > now() - interval '7 days') >= 3;

  if v_hide then
    perform set_config('hololoco.system', 'on', true);
    update public.drops d set review = 'pending', review_reason = null where d.id = v_drop.id;
    perform set_config('hololoco.system', '', true);
    insert into public.moderation_events (drop_id, drop_title, actor_id, action, reason)
    values (v_drop.id, v_drop.title, null, 'hide', 'Hidden after a report: ' || file_report.reason);
  end if;

  return jsonb_build_object('filed', true, 'hidden', v_hide);
end;
$$;

revoke execute on function public.file_report(text, text, text, text) from public;
grant execute on function public.file_report(text, text, text, text) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- Staff: reports alongside the queue.
-- ---------------------------------------------------------------------------

-- Reported drops (with their open reports) and requests not about one drop, oldest first.
create function public.review_reports()
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
    select x.item from (
      select jsonb_build_object(
          'kind', 'drop',
          'drop', public.drop_to_json(d),
          'hidden', d.review = 'pending',
          'reports', (select jsonb_agg(jsonb_build_object(
                         'id', r.id, 'reason', r.reason, 'details', r.details, 'contact', r.contact,
                         'at', r.created_at, 'signedIn', r.reporter_id is not null) order by r.created_at)
                      from public.reports r where r.drop_id = d.id and r.status = 'open')) as item,
        (select min(r.created_at) from public.reports r where r.drop_id = d.id and r.status = 'open') as first_at
      from public.drops d
      where exists (select 1 from public.reports r where r.drop_id = d.id and r.status = 'open')
      union all
      select jsonb_build_object(
          'kind', 'request',
          'drop', null,
          'hidden', false,
          'dropTitle', r.drop_title,
          'reports', jsonb_build_array(jsonb_build_object(
                       'id', r.id, 'reason', r.reason, 'details', r.details, 'contact', r.contact,
                       'at', r.created_at, 'signedIn', r.reporter_id is not null))),
        r.created_at
      from public.reports r
      where r.status = 'open'
        and (r.drop_id is null or not exists (select 1 from public.drops d where d.id = r.drop_id))
    ) x
    order by x.first_at asc
    limit 200;
end;
$$;

-- Close one report that isn't about a drop on the map (a removal request, or a
-- report whose drop was deleted).
create function public.close_report(report_id bigint, outcome text, note text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_staff() then
    raise exception 'not_staff' using errcode = 'P0001';
  end if;
  if close_report.outcome not in ('resolved', 'dismissed') then
    raise exception 'bad_decision' using errcode = 'P0001';
  end if;
  update public.reports r set
    status = close_report.outcome,
    resolution = nullif(btrim(close_report.note), ''),
    resolved_by = auth.uid(),
    resolved_at = now()
  where r.id = close_report.report_id and r.status = 'open';
  if not found then
    raise exception 'not_found' using errcode = 'P0001';
  end if;
end;
$$;

-- Drops with open reports wait in the reports list instead of the queue.
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
      'ownerSince', (select p.created_at from public.profiles p where p.id = d.owner_id))
    from public.drops d
    where d.review = 'pending'
      and not exists (select 1 from public.reports r where r.drop_id = d.id and r.status = 'open')
    order by d.created_at asc
    limit 200;
end;
$$;

-- Deciding on a drop also closes its open reports: approving keeps it (the
-- reports are dismissed), not approving takes it down (they're resolved).
create or replace function public.review_drop(drop_id text, decision text, reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_drop public.drops;
  v_reason text := nullif(btrim(review_drop.reason), '');
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

  update public.drops d set
    review = case review_drop.decision when 'approve' then 'approved' when 'reject' then 'rejected' else 'pending' end,
    review_reason = case when review_drop.decision = 'reject' then v_reason end
  where d.id = review_drop.drop_id
  returning d.* into v_drop;

  if v_drop.id is null then
    raise exception 'not_found' using errcode = 'P0001';
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

-- Owners see when their drop is hidden because of a report (but not who reported it).
create or replace function public.my_drops()
returns setof jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select public.drop_to_json(d) || jsonb_build_object(
    'hiddenForReport', d.review = 'pending'
      and exists (select 1 from public.reports r where r.drop_id = d.id and r.status = 'open'))
  from public.drops d
  where d.owner_id = (select auth.uid())
  order by d.created_at desc;
$$;

revoke execute on function public.review_reports() from public, anon;
revoke execute on function public.close_report(bigint, text, text) from public, anon;
grant execute on function public.review_reports() to authenticated;
grant execute on function public.close_report(bigint, text, text) to authenticated;
