-- Hololoco, part 2: the review queue (Phase 3).
--
-- Staff approve or reject drops that are waiting, and every rejection gives a
-- reason the owner sees. Every decision goes into moderation_events, which
-- nobody can change or delete through the API. Editing a drop that wasn't
-- approved sends it back for review.

alter table public.drops
  add column review_reason text check (review_reason is null or char_length(review_reason) between 1 and 300);

-- The moderation log. It keeps the drop's id and title even after the drop is deleted.
create table public.moderation_events (
  id bigint generated always as identity primary key,
  drop_id text not null,
  drop_title text not null,
  actor_id uuid references public.profiles (id) on delete set null,
  action text not null check (action in ('approve', 'reject', 'reopen')),
  reason text check (reason is null or char_length(reason) <= 300),
  created_at timestamptz not null default now()
);

create index moderation_events_created_idx on public.moderation_events (created_at desc);
create index moderation_events_drop_idx on public.moderation_events (drop_id);
create index moderation_events_actor_idx on public.moderation_events (actor_id);

-- No policies and no grants: only the staff functions below read or write it.
alter table public.moderation_events enable row level security;
revoke all on table public.moderation_events from anon, authenticated;

-- ---------------------------------------------------------------------------
-- The write rules, now also sending edited, rejected drops back for review.
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
  -- No signed-in user means the service role or the SQL editor: trusted.
  if me is null then
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

-- The drop's JSON, now with the reason it wasn't approved (only ever set on
-- rejected drops, which the public functions never return).
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
-- Staff functions. Each checks the caller is staff; everyone else gets not_staff.
-- ---------------------------------------------------------------------------

-- Drops waiting for review, oldest first, with what a reviewer needs about the owner.
create function public.review_queue()
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
    order by d.created_at asc
    limit 200;
end;
$$;

-- Approve, reject (a reason is required) or reopen a drop, and log it.
create function public.review_drop(drop_id text, decision text, reason text default null)
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

  return public.drop_to_json(v_drop);
end;
$$;

-- The latest decisions, newest first.
create function public.review_history(max_results integer default 30)
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
      'by', coalesce(p.display_name, 'Staff'),
      'review', d.review)
    from public.moderation_events e
    left join public.profiles p on p.id = e.actor_id
    left join public.drops d on d.id = e.drop_id
    order by e.created_at desc, e.id desc
    limit least(greatest(max_results, 1), 100);
end;
$$;

revoke execute on function public.review_queue() from public, anon;
revoke execute on function public.review_drop(text, text, text) from public, anon;
revoke execute on function public.review_history(integer) from public, anon;
grant execute on function public.review_queue() to authenticated;
grant execute on function public.review_drop(text, text, text) to authenticated;
grant execute on function public.review_history(integer) to authenticated;
