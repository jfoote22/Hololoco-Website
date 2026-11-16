-- Hololoco, part 12: offers whose value drops over time.
--
-- A business can give an offer a value in dollars and have it lose a share of
-- that value every so many days after it's posted, so people hurry to collect
-- and redeem it, as old Coupemon's coupons did. The database works out what it's
-- worth now from its own clock (old Coupemon used the phone's, so changing the
-- phone's clock changed the value).
--
--   value now = value × (1 − decay % / 100) ^ (whole periods of decay_days since posting), never below 0
--
-- An item in someone's bag keeps losing value until it's redeemed; the business
-- sees what it's worth at the counter.

alter table public.offers
  -- US cents. Null: no value given, so nothing to lose.
  add column value_cents integer check (value_cents is null or value_cents between 1 and 100000000),
  add column decay_percent smallint not null default 0 check (decay_percent between 0 and 90),
  add column decay_days smallint not null default 7 check (decay_days between 1 and 365);

grant insert (value_cents, decay_percent, decay_days) on table public.offers to authenticated;
grant update (value_cents, decay_percent, decay_days) on table public.offers to authenticated;

create function public.offer_value_now(p_value integer, p_percent integer, p_days integer, p_since timestamptz)
returns integer
language sql
stable
set search_path = ''
as $$
  select case
    when p_value is null then null
    when coalesce(p_percent, 0) <= 0 or p_since is null then p_value
    else greatest(0, round(p_value * power(1 - p_percent / 100.0,
           floor(greatest(extract(epoch from now() - p_since), 0) / 86400.0 / greatest(p_days, 1)))))::integer
  end;
$$;

grant execute on function public.offer_value_now(integer, integer, integer, timestamptz) to anon, authenticated;

-- Saving: the offer's value and how it drops.
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
      tradeable = coalesce((v_offer ->> 'tradeable')::boolean, true),
      value_cents = nullif(v_offer ->> 'valueCents', '')::integer,
      decay_percent = coalesce(nullif(v_offer ->> 'decayPercent', '')::smallint, 0),
      decay_days = coalesce(nullif(v_offer ->> 'decayDays', '')::smallint, 7)
    where drop_id = v_id;
    if not found then
      insert into public.offers (drop_id, savings, terms, quantity, per_person, rarity, in_quests, kind, category, tradeable,
                                 value_cents, decay_percent, decay_days)
      values (v_id, btrim(v_offer ->> 'savings'), btrim(coalesce(v_offer ->> 'terms', '')),
              (v_offer ->> 'quantity')::integer, (v_offer ->> 'perPerson')::smallint,
              coalesce(v_offer ->> 'rarity', 'common'), coalesce((v_offer ->> 'inQuests')::boolean, false),
              coalesce(v_offer ->> 'kind', 'deal'), coalesce(v_offer ->> 'category', 'other'),
              coalesce((v_offer ->> 'tradeable')::boolean, true),
              nullif(v_offer ->> 'valueCents', '')::integer,
              coalesce(nullif(v_offer ->> 'decayPercent', '')::smallint, 0),
              coalesce(nullif(v_offer ->> 'decayDays', '')::smallint, 7));
    end if;
  else
    delete from public.offers where drop_id = v_id;
  end if;

  return v_id;
end;
$$;

-- Reading: the value, how it drops, and what it's worth now.
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

-- What a held item is worth now, from what the offer said when it was captured.
create function public.item_value_now(snapshot jsonb)
returns integer
language sql
stable
set search_path = ''
as $$
  select public.offer_value_now(
    nullif(snapshot -> 'offer' ->> 'valueCents', '')::integer,
    coalesce(nullif(snapshot -> 'offer' ->> 'decayPercent', '')::integer, 0),
    coalesce(nullif(snapshot -> 'offer' ->> 'decayDays', '')::integer, 7),
    nullif(snapshot -> 'offer' ->> 'valueSince', '')::timestamptz);
$$;

revoke execute on function public.item_value_now(jsonb) from public, anon, authenticated;

create or replace function public.item_to_json(i public.inventory)
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
    'valueNowCents', case when i.status = 'held' or i.status = 'dropped' then public.item_value_now(i.snapshot) end,
    'at', i.created_at,
    'redeemedAt', i.redeemed_at,
    'redemption', (select jsonb_build_object('code', r.code, 'expiresAt', r.expires_at)
                   from public.redemptions r
                   where r.item_id = i.id and r.player_id = i.owner_id and r.confirmed_at is null and r.expires_at > now()
                   order by r.id desc limit 1),
    'onMap', (select jsonb_build_object('lat', l.lat, 'lng', l.lng, 'expiresAt', l.expires_at)
              from public.loose_items l where l.item_id = i.id));
$$;

-- The business sees what the offer is worth at the counter.
create or replace function public.confirm_redemption(code text)
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
  v_worth integer;
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
  select * into v_item from public.inventory i where i.id = v_row.item_id;
  v_worth := public.item_value_now(v_item.snapshot);
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
    'valueNowCents', v_worth,
    'player', (select coalesce(p.handle, p.display_name, 'A player') from public.profiles p where p.id = v_row.player_id),
    'at', now());
end;
$$;
