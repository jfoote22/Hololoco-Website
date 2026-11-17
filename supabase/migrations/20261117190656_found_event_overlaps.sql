-- Found events: a run of shows (holiday lights, a play's run) is found again each day
-- with that day as its start. Catch it as a duplicate when the times overlap.

create or replace function private.found_save_event(p_search bigint, p_area text, p_event jsonb)
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

  -- The same event: the same key, or a close title at the same place on the same day
  -- or at overlapping times. A run of shows is found again each day with that day as
  -- its start, so overlapping times catch it too.
  select e.id into v_existing
  from public.found_events e
  where e.dedupe_key = v_key
     or (e.area_id = area.id
         and ((e.starts_at at time zone area.time_zone)::date = (v_starts at time zone area.time_zone)::date
              or (e.starts_at < v_ends and v_starts < e.ends_at))
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
