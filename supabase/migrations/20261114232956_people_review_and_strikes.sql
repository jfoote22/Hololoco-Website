-- Hololoco, part 6: live at once, a person reviews after a complaint, three strikes.
--
-- People do every review for now; the automatic check is switched off.
--   * Drops from accounts in good standing go live as soon as they're saved.
--   * A complaint (an open report about any of an account's drops) puts the
--     account under review: its new drops and its changes wait for a person.
--     Keeping the reported drop (dismissing the reports) returns the account to
--     good standing, unless it has a strike.
--   * Each drop a person takes down or doesn't approve is a strike, and an account
--     with a strike stays under review. Three strikes suspend it: its drops leave
--     the map, and it can't add or change any. Undoing a decision takes its strike back.
--   * Photos and 3D models still always wait for a person.
--
-- Lift a suspension in the SQL editor: update public.profiles set strikes = 0 where id = '<user id>';
-- Turn the automatic check back on (with ANTHROPIC_API_KEY set on check-drop):
--   select private.set_automatic_check(true);
-- While it's on, it looks first at whatever would otherwise wait for a person.

alter table public.profiles add column strikes smallint not null default 0 check (strikes >= 0);

-- Drops a person turned down before this migration count as strikes.
update public.profiles p set strikes = least(
  (select count(*) from public.drops d where d.owner_id = p.id and d.review = 'rejected'), 32767);

-- ---------------------------------------------------------------------------
-- The automatic check's switch
-- ---------------------------------------------------------------------------

create table private.settings (
  name text primary key,
  value text not null
);

create function private.automatic_check_on()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((select s.value = 'on' from private.settings s where s.name = 'automatic_check'), false);
$$;

-- Turns the check on or off, with the job that retries it.
create function private.set_automatic_check(p_on boolean)
returns text
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into private.settings (name, value) values ('automatic_check', case when p_on then 'on' else 'off' end)
  on conflict (name) do update set value = excluded.value;
  if p_on then
    perform cron.schedule('retry-drop-checks', '* * * * *', 'select private.retry_checks()');
  elsif exists (select 1 from cron.job j where j.jobname = 'retry-drop-checks') then
    perform cron.unschedule('retry-drop-checks');
  end if;
  return case when p_on then 'on' else 'off' end;
end;
$$;

revoke execute on function private.automatic_check_on() from public, anon, authenticated;
revoke execute on function private.set_automatic_check(boolean) from public, anon, authenticated;

select private.set_automatic_check(false);

-- ---------------------------------------------------------------------------
-- An account's standing
-- ---------------------------------------------------------------------------

-- good: its drops go live at once. review: a complaint is open or it has a
-- strike, so its new drops and changes wait for a person. suspended: three strikes.
create function public.account_standing(p_owner uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when p.strikes >= 3 then 'suspended'
    when p.strikes > 0
      or exists (select 1 from public.reports r join public.drops d on d.id = r.drop_id
                 where d.owner_id = p.id and r.status = 'open') then 'review'
    else 'good'
  end
  from public.profiles p where p.id = p_owner;
$$;

revoke execute on function public.account_standing(uuid) from public, anon, authenticated;

-- The signed-in person's own standing, so the website can explain it.
create function public.my_standing()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object('standing', public.account_standing(p.id), 'strikes', p.strikes)
  from public.profiles p where p.id = (select auth.uid());
$$;

revoke execute on function public.my_standing() from public, anon;
grant execute on function public.my_standing() to authenticated;

-- ---------------------------------------------------------------------------
-- The write rules
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
  standing text;
  needs_person boolean := false;
begin
  -- No signed-in user means the service role or the SQL editor, and
  -- hololoco.system means one of the database's own functions: both trusted.
  if me is null or coalesce(current_setting('hololoco.system', true), '') = 'on' then
    new.updated_at := now();
    return new;
  end if;

  if not staff then
    standing := public.account_standing(me);
    if standing = 'suspended' then
      raise exception 'account_suspended' using errcode = 'P0001';
    end if;
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

    -- Live at once, unless the account is under review.
    if staff or standing = 'good' then
      new.review := 'approved';
    else
      new.review := 'pending';
      needs_person := true;
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
    -- Editing a drop that wasn't approved, or (for an account under review)
    -- changing what a drop says, looks like or where it is, waits for a person.
    if not staff and (old.review = 'rejected'
                      or (standing <> 'good'
                          and (new.type <> old.type
                               or new.title <> old.title
                               or new.description <> old.description
                               or new.object_id is distinct from old.object_id
                               or new.asset_id is distinct from old.asset_id
                               or new.lat <> old.lat
                               or new.lng <> old.lng))) then
      new.review := 'pending';
      new.review_reason := null;
      needs_person := true;
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
      needs_person := true;
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

  -- With the automatic check on, it looks first at whatever would wait for a person.
  if needs_person and not staff and private.automatic_check_on() then
    new.check_state := 'queued';
    new.check_at := now();
    new.check_attempts := 0;
  end if;

  new.updated_at := now();
  return new;
end;
$$;

-- For an account under review, changing what an offer gives, its terms or its
-- rarity waits for a person too. Suspended accounts can't change offers.
create or replace function public.offers_before_write()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
  standing text;
begin
  if tg_op = 'INSERT' then
    new.claimed := 0;
    new.created_at := now();
  elsif new.drop_id <> old.drop_id then
    raise exception 'not_allowed' using errcode = 'P0001';
  end if;
  new.updated_at := now();

  if me is null or coalesce(current_setting('hololoco.system', true), '') = 'on' or public.is_staff() then
    return new;
  end if;

  standing := public.account_standing(me);
  if standing = 'suspended' then
    raise exception 'account_suspended' using errcode = 'P0001';
  end if;

  if tg_op = 'UPDATE' and standing <> 'good'
     and (new.savings <> old.savings or new.terms <> old.terms or new.rarity <> old.rarity) then
    perform set_config('hololoco.system', 'on', true);
    update public.drops d set review = 'pending', review_reason = null where d.id = new.drop_id;
    if private.automatic_check_on() then
      update public.drops d set check_state = 'queued', check_at = now(), check_attempts = 0
      where d.id = new.drop_id and d.check_state is distinct from 'queued';
    end if;
    perform set_config('hololoco.system', '', true);
  end if;
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- A suspended account's drops leave the map and their pages.
-- ---------------------------------------------------------------------------

create or replace function public.drop_on_map(d public.drops)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select d.review = 'approved' and not d.paused and d.audience = 'everyone' and public.drop_is_open(d)
    and not exists (select 1 from public.profiles p where p.id = d.owner_id and p.strikes >= 3);
$$;

create or replace function public.public_drop(drop_id text)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select public.drop_to_json(d)
  from public.drops d
  where d.id = drop_id and d.review = 'approved' and not d.paused
    and not exists (select 1 from public.profiles p where p.id = d.owner_id and p.strikes >= 3);
$$;

-- ---------------------------------------------------------------------------
-- Staff: strikes come with decisions, and the queue shows them.
-- ---------------------------------------------------------------------------

-- Not approving a drop, or taking one down, is a strike for its owner; undoing
-- that decision takes the strike back.
create or replace function public.review_drop(drop_id text, decision text, reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_drop public.drops;
  v_before text;
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

  select d.review into v_before from public.drops d where d.id = review_drop.drop_id;

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

  if review_drop.decision = 'reject' and v_before is distinct from 'rejected' then
    update public.profiles p set strikes = p.strikes + 1 where p.id = v_drop.owner_id;
  elsif review_drop.decision = 'reopen' and v_before = 'rejected' then
    update public.profiles p set strikes = greatest(p.strikes - 1, 0) where p.id = v_drop.owner_id;
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
      'ownerStrikes', (select p.strikes from public.profiles p where p.id = d.owner_id),
      'ownerStanding', public.account_standing(d.owner_id),
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

-- Reported drops now come with their owner's strikes, so staff know what taking one down means.
create or replace function public.review_reports()
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
          'ownerStrikes', (select p.strikes from public.profiles p where p.id = d.owner_id),
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
