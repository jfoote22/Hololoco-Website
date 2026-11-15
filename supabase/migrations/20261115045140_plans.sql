-- Hololoco, part 9: plans.
--
-- Every account has a plan. The plan sets how many drops it can have and what
-- kinds it can add; the database enforces it.
--   * Free: messages and objects, with a ready-made look or a photo. 10 drops at a time.
--   * Plus: paid placements. More drops, and uploaded 3D models.
--   * Business: offers too: coupons, giveaways and gift cards.
--   * Events: custom events at the business's own drops, for bonus XP, points and a reward.
-- Each plan includes everything in the ones before it. Staff have no limits.
--
-- There's no payment yet: people ask for a plan on the website and staff grant it
-- (decide_plan_request). Change a plan's limits in the plans table; the website
-- reads them from there. Give someone a plan directly:
--   select public.set_plan('<user id>', 'business');  -- as staff, or in the SQL editor
--
-- Offers also gain a kind (coupon, giveaway or gift card), a category (which
-- themes quests), and whether people can trade them in the app.

create table public.plans (
  id text primary key check (id in ('free', 'plus', 'business', 'events')),
  name text not null,
  position smallint not null unique,
  blurb text not null,
  -- Drops at a time (all but those turned down) and new drops a day.
  max_drops integer not null check (max_drops between 1 and 100000),
  daily_drops integer not null check (daily_drops between 1 and 10000),
  models boolean not null,
  offers boolean not null,
  events boolean not null,
  -- US cents a month. Null until there's a price; the website then says it's free while testing.
  monthly_cents integer check (monthly_cents is null or monthly_cents >= 0)
);

alter table public.plans enable row level security;
create policy "Anyone reads the plans" on public.plans for select to anon, authenticated using (true);
revoke all on table public.plans from anon, authenticated;
grant select on table public.plans to anon, authenticated;

insert into public.plans (id, name, position, blurb, max_drops, daily_drops, models, offers, events, monthly_cents) values
  ('free', 'Free', 1, 'Messages and pictures on the map.', 10, 5, false, false, false, 0),
  ('plus', 'Plus', 2, 'More pins, and your own 3D models.', 50, 20, true, false, false, null),
  ('business', 'Business', 3, 'Coupons, giveaways and gift cards people collect and redeem at your business.', 200, 50, true, true, false, null),
  ('events', 'Events', 4, 'Your own events and games across your locations, with bonus XP, points and rewards.', 500, 100, true, true, true, null);

alter table public.profiles
  add column plan text not null default 'free' references public.plans (id),
  -- When a paid plan ends. Null: it doesn't. Set by payments later.
  add column plan_until timestamptz;

create index profiles_plan_idx on public.profiles (plan);

-- Accounts that already have offers keep them: they're businesses.
update public.profiles p set plan = 'business'
where exists (select 1 from public.drops d where d.owner_id = p.id and d.type = 'offer');

-- ---------------------------------------------------------------------------
-- What an account can do
-- ---------------------------------------------------------------------------

-- The plan in force: a lapsed paid plan counts as Free.
create function public.plan_of(p_user uuid)
returns public.plans
language sql
stable
security definer
set search_path = ''
as $$
  select pl.* from public.plans pl
  where pl.id = coalesce((select case when p.plan_until is null or p.plan_until > now() then p.plan else 'free' end
                          from public.profiles p where p.id = p_user), 'free');
$$;

revoke execute on function public.plan_of(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Offers: kind, category, trading
-- ---------------------------------------------------------------------------

-- What kind of business an offer is from. Quests made of one category get a theme.
create table public.offer_categories (
  id text primary key check (id ~ '^[a-z]{2,20}$'),
  name text not null,
  -- The name of a quest made only of this category, or null for no theme.
  theme text,
  position smallint not null unique
);

alter table public.offer_categories enable row level security;
create policy "Anyone reads the categories" on public.offer_categories for select to anon, authenticated using (true);
revoke all on table public.offer_categories from anon, authenticated;
grant select on table public.offer_categories to anon, authenticated;

insert into public.offer_categories (id, name, theme, position) values
  ('coffee', 'Coffee and tea', 'Coffee crawl', 1),
  ('food', 'Food', 'Food trail', 2),
  ('sweets', 'Bakery and sweets', 'Sweet tooth trail', 3),
  ('drinks', 'Bars and drinks', 'Drinks trail', 4),
  ('shopping', 'Shopping', 'Shop hop', 5),
  ('beauty', 'Beauty and wellness', 'Treat yourself trail', 6),
  ('fitness', 'Fitness and outdoors', 'Active trail', 7),
  ('fun', 'Fun and entertainment', 'Fun trail', 8),
  ('services', 'Services', null, 9),
  ('other', 'Something else', null, 10);

alter table public.offers
  -- deal: a coupon or discount. giveaway: something free. gift_card: a gift card or certificate.
  add column kind text not null default 'deal' check (kind in ('deal', 'giveaway', 'gift_card')),
  add column category text not null default 'other' references public.offer_categories (id),
  -- Whether people can trade it or leave it on the map for someone else.
  add column tradeable boolean not null default true;

grant insert (kind, category, tradeable) on table public.offers to authenticated;
grant update (kind, category, tradeable) on table public.offers to authenticated;

-- ---------------------------------------------------------------------------
-- The rules: plan limits on drops and uploads
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
  plan public.plans;
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
    plan := public.plan_of(me);
    -- Offers need the Business plan. An existing offer stays editable.
    if new.type = 'offer' and not plan.offers and (tg_op = 'INSERT' or old.type <> 'offer') then
      raise exception 'plan_offers' using errcode = 'P0001';
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
      if (select count(*) from public.drops d where d.owner_id = me and d.review <> 'rejected') >= plan.max_drops then
        raise exception 'limit_total' using errcode = 'P0001';
      end if;
      if (select count(*) from public.drops d
          where d.owner_id = me and d.created_at > now() - interval '1 day') >= plan.daily_drops then
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
    if asset.kind = 'model' and not staff and not plan.models then
      raise exception 'plan_models' using errcode = 'P0001';
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

-- Uploading a 3D model needs a plan with models; photos are free.
create function public.assets_plan_before_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
begin
  if me is null or coalesce(current_setting('hololoco.system', true), '') = 'on' or public.is_staff() then
    return new;
  end if;
  if new.kind = 'model' and not (public.plan_of(me)).models then
    raise exception 'plan_models' using errcode = 'P0001';
  end if;
  return new;
end;
$$;

revoke execute on function public.assets_plan_before_insert() from public, anon, authenticated;

create trigger assets_plan_before_insert
  before insert on public.assets
  for each row execute function public.assets_plan_before_insert();

-- ---------------------------------------------------------------------------
-- Saving and reading offers, with the new fields
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
      in_quests = coalesce((v_offer ->> 'inQuests')::boolean, false),
      kind = coalesce(v_offer ->> 'kind', 'deal'),
      category = coalesce(v_offer ->> 'category', 'other'),
      tradeable = coalesce((v_offer ->> 'tradeable')::boolean, true)
    where drop_id = v_id;
    if not found then
      insert into public.offers (drop_id, savings, terms, quantity, per_person, rarity, in_quests, kind, category, tradeable)
      values (v_id, btrim(v_offer ->> 'savings'), btrim(coalesce(v_offer ->> 'terms', '')),
              (v_offer ->> 'quantity')::integer, (v_offer ->> 'perPerson')::smallint,
              coalesce(v_offer ->> 'rarity', 'common'), coalesce((v_offer ->> 'inQuests')::boolean, false),
              coalesce(v_offer ->> 'kind', 'deal'), coalesce(v_offer ->> 'category', 'other'),
              coalesce((v_offer ->> 'tradeable')::boolean, true));
    end if;
  else
    delete from public.offers where drop_id = v_id;
  end if;

  return v_id;
end;
$$;

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
                'kind', o.kind, 'category', o.category, 'tradeable', o.tradeable)
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

-- ---------------------------------------------------------------------------
-- Asking for a plan, and staff granting it
-- ---------------------------------------------------------------------------

create table public.plan_requests (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles (id) on delete cascade,
  plan text not null references public.plans (id),
  -- What they'll use it for: the business's name and address, say.
  note text not null check (char_length(btrim(note)) between 1 and 500),
  status text not null default 'open' check (status in ('open', 'granted', 'declined', 'withdrawn')),
  answer text check (answer is null or char_length(answer) <= 500),
  decided_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  decided_at timestamptz
);

create unique index plan_requests_one_open_idx on public.plan_requests (user_id) where status = 'open';
create index plan_requests_status_idx on public.plan_requests (status, created_at);
create index plan_requests_decided_by_idx on public.plan_requests (decided_by);

alter table public.plan_requests enable row level security;
revoke all on table public.plan_requests from anon, authenticated;

-- The signed-in person's plan, what it allows, how much of it they use, their
-- open request, and every plan to compare.
create function public.my_plan()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'plan', pl.id,
    'until', p.plan_until,
    'staff', p.is_staff,
    'drops', (select count(*) from public.drops d where d.owner_id = p.id and d.review <> 'rejected'),
    'dropsToday', (select count(*) from public.drops d where d.owner_id = p.id and d.created_at > now() - interval '1 day'),
    'request', (select jsonb_build_object('id', r.id, 'plan', r.plan, 'status', r.status, 'note', r.note,
                                          'answer', r.answer, 'at', r.created_at, 'decidedAt', r.decided_at)
                from public.plan_requests r where r.user_id = p.id
                  and (r.status = 'open' or r.decided_at > now() - interval '14 days')
                order by r.id desc limit 1),
    'plans', (select jsonb_agg(jsonb_build_object(
                  'id', x.id, 'name', x.name, 'blurb', x.blurb, 'maxDrops', x.max_drops, 'dailyDrops', x.daily_drops,
                  'models', x.models, 'offers', x.offers, 'events', x.events, 'monthlyCents', x.monthly_cents)
                order by x.position)
              from public.plans x))
  from public.profiles p
  cross join lateral public.plan_of(p.id) pl
  where p.id = (select auth.uid());
$$;

revoke execute on function public.my_plan() from public, anon;
grant execute on function public.my_plan() to authenticated;

-- Ask for a plan. One open request at a time; asking again replaces it.
create function public.request_plan(plan text, note text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
  v_note text := btrim(coalesce(request_plan.note, ''));
  v_id bigint;
begin
  if me is null then
    raise exception 'sign_in_needed' using errcode = 'P0001';
  end if;
  if not exists (select 1 from public.plans p where p.id = request_plan.plan) or request_plan.plan = 'free' then
    raise exception 'bad_plan' using errcode = 'P0001';
  end if;
  if (public.plan_of(me)).id = request_plan.plan then
    raise exception 'already_on_plan' using errcode = 'P0001';
  end if;
  if char_length(v_note) not between 1 and 500 then
    raise exception 'note_needed' using errcode = 'P0001';
  end if;
  if (select count(*) from public.plan_requests r where r.user_id = me and r.created_at > now() - interval '1 day') >= 5 then
    raise exception 'limit_requests' using errcode = 'P0001';
  end if;

  update public.plan_requests r set status = 'withdrawn', decided_at = now()
  where r.user_id = me and r.status = 'open';
  insert into public.plan_requests (user_id, plan, note) values (me, request_plan.plan, v_note) returning id into v_id;
  return jsonb_build_object('id', v_id, 'plan', request_plan.plan, 'status', 'open');
end;
$$;

create function public.withdraw_plan_request()
returns void
language sql
security definer
set search_path = ''
as $$
  update public.plan_requests r set status = 'withdrawn', decided_at = now()
  where r.user_id = (select auth.uid()) and r.status = 'open';
$$;

-- Staff: open requests, oldest first, with who's asking.
create function public.plan_requests_queue()
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
      'id', r.id, 'plan', r.plan, 'note', r.note, 'at', r.created_at,
      'user', jsonb_build_object(
        'id', p.id, 'name', coalesce(p.display_name, 'No name yet'), 'email', u.email,
        'plan', p.plan, 'since', p.created_at, 'strikes', p.strikes,
        'drops', (select count(*) from public.drops d where d.owner_id = p.id and d.review <> 'rejected')))
    from public.plan_requests r
    join public.profiles p on p.id = r.user_id
    left join auth.users u on u.id = p.id
    where r.status = 'open'
    order by r.created_at
    limit 200;
end;
$$;

-- Staff: grant or decline a request.
create function public.decide_plan_request(request_id bigint, grant_it boolean, answer text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_request public.plan_requests;
begin
  if not public.is_staff() then
    raise exception 'not_staff' using errcode = 'P0001';
  end if;
  update public.plan_requests r set
    status = case when grant_it then 'granted' else 'declined' end,
    answer = nullif(btrim(decide_plan_request.answer), ''),
    decided_by = auth.uid(),
    decided_at = now()
  where r.id = request_id and r.status = 'open'
  returning r.* into v_request;
  if v_request.id is null then
    raise exception 'not_found' using errcode = 'P0001';
  end if;
  if grant_it then
    update public.profiles p set plan = v_request.plan, plan_until = null where p.id = v_request.user_id;
  end if;
  return jsonb_build_object('id', v_request.id, 'status', v_request.status);
end;
$$;

-- Staff (or the SQL editor): set someone's plan directly.
create function public.set_plan(user_id uuid, plan text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is not null and not public.is_staff() then
    raise exception 'not_staff' using errcode = 'P0001';
  end if;
  if not exists (select 1 from public.plans p where p.id = set_plan.plan) then
    raise exception 'bad_plan' using errcode = 'P0001';
  end if;
  update public.profiles p set plan = set_plan.plan, plan_until = null where p.id = set_plan.user_id;
  update public.plan_requests r set status = 'granted', decided_by = auth.uid(), decided_at = now()
  where r.user_id = set_plan.user_id and r.status = 'open' and r.plan = set_plan.plan;
end;
$$;

revoke execute on function public.request_plan(text, text) from public, anon;
revoke execute on function public.withdraw_plan_request() from public, anon;
revoke execute on function public.plan_requests_queue() from public, anon;
revoke execute on function public.decide_plan_request(bigint, boolean, text) from public, anon;
revoke execute on function public.set_plan(uuid, text) from public, anon;
grant execute on function public.request_plan(text, text) to authenticated;
grant execute on function public.withdraw_plan_request() to authenticated;
grant execute on function public.plan_requests_queue() to authenticated;
grant execute on function public.decide_plan_request(bigint, boolean, text) to authenticated;
grant execute on function public.set_plan(uuid, text) to authenticated;
