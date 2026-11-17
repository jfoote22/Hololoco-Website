-- Approved events' looks, in one place: the library's "note" is a speech bubble, so
-- comedy gets it and music gets the star. Keep in step with categoryObject in lib/found.ts.

create function private.found_object(p_category text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case p_category
    when 'comedy' then 'note'
    when 'community' then 'heart'
    when 'family' then 'heart'
    when 'food' then 'pizza'
    when 'business' then 'cup'
    when 'giveaway' then 'gift'
    when 'deal' then 'gift'
    else 'star'
  end;
$$;

revoke execute on function private.found_object(text) from public, anon, authenticated;

create or replace function public.review_found(
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
    v_object := private.found_object(e.category);
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
