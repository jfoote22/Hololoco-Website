-- Hololoco, part 11: quest themes.
--
-- Offers now say what kind of business they're from (offer_categories). When the
-- builder can make a quest entirely from one category that has a theme, it does
-- that first: a coffee crawl, a food trail, a shop hop. Otherwise it builds a
-- mixed quest as before. Shorter walks still come first: at each distance, themed
-- quests, then mixed ones.
--
-- A themed quest retires if one of its offers changes to a different category.

alter table public.quests add column theme text references public.offer_categories (id);
create index quests_theme_idx on public.quests (theme);

-- The first reason a quest can't go on, or null if it can. Now also: a themed
-- quest's offers must stay in its category.
create or replace function private.quest_problem(p_quest text)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_quest public.quests;
  v_stage record;
  v_drop public.drops;
  v_prev extensions.geography;
  v_mask bit(168) := repeat('1', 168)::bit(168);
  v_problem text;
  v_count integer := 0;
begin
  select * into v_quest from public.quests q where q.id = p_quest;
  for v_stage in select s.position, s.rarity, s.drop_id from public.quest_stages s
                 where s.quest_id = p_quest order by s.position loop
    v_count := v_count + 1;
    v_problem := private.quest_stage_problem(v_stage.drop_id, v_stage.rarity);
    if v_problem is not null then
      return format('Stage %s %s.', v_stage.position, v_problem);
    end if;
    if v_quest.theme is not null
       and (select o.category from public.offers o where o.drop_id = v_stage.drop_id) <> v_quest.theme then
      return format('Stage %s is a different kind of business now.', v_stage.position);
    end if;
    select * into v_drop from public.drops d where d.id = v_stage.drop_id;
    if v_drop.time_zone <> v_quest.time_zone then
      return format('Stage %s is in a different time zone now.', v_stage.position);
    end if;
    if v_prev is not null
       and extensions.st_distance(v_prev, v_drop.geom::extensions.geography) > v_quest.max_leg_m * 1.25 then
      return format('Stage %s moved too far from the one before.', v_stage.position);
    end if;
    v_prev := v_drop.geom::extensions.geography;
    v_mask := v_mask & public.drop_week_hours(v_drop);
  end loop;
  if v_count < v_quest.stage_count then
    return 'A stage was deleted.';
  end if;
  if bit_count(v_mask) < 4 then
    return 'Its stages are no longer open together 4 hours a week.';
  end if;
  return null;
end;
$$;

-- Builds as many new quests as it can from offers not in one yet: for each
-- distance (a 20-minute walk, then 5 km, then 15 km), first quests of a single
-- themed category, then mixed ones. Each starts from a rare offer and finds the
-- nearest uncommon one, perhaps a second before that, and the nearest common one.
create or replace function private.build_quests()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_min_hours constant integer := 4;
  v_tier integer;
  v_theme record;
  v_rare record;
  v_late record;
  v_early record;
  v_first record;
  v_has_early boolean;
  v_mask bit(168);
  v_owners uuid[];
  v_quest text;
  v_built integer := 0;
begin
  drop table if exists pg_temp.quest_pool;
  create temp table quest_pool as
    select d.id, d.owner_id, o.rarity, o.category, d.time_zone, d.created_at,
           d.geom::extensions.geography as geog,
           public.drop_week_hours(d) as hours,
           false as used
    from public.drops d
    join public.offers o on o.drop_id = d.id
    join public.profiles p on p.id = d.owner_id
    where d.type = 'offer' and o.in_quests and o.claimed < o.quantity
      and d.review = 'approved' and not d.paused and d.audience = 'everyone'
      and d.timing in ('always', 'weekly') and p.strikes < 3
      and not exists (select 1 from public.quest_stages s join public.quests q on q.id = s.quest_id
                      where s.drop_id = d.id and q.status = 'active');
  delete from pg_temp.quest_pool where bit_count(hours) < v_min_hours;

  foreach v_tier in array array[1600, 5000, 15000] loop
    -- Themed passes (one per category with a theme), then a mixed pass (theme null).
    for v_theme in
      select c.id, c.theme, c.position from public.offer_categories c where c.theme is not null
      union all
      select null::text, null::text, 1000::smallint
      order by 3
    loop
      for v_rare in select * from pg_temp.quest_pool
                    where rarity = 'rare' and not used and (v_theme.id is null or category = v_theme.id)
                    order by created_at, id loop
        -- The last uncommon stage: the nearest to the rare one.
        select * into v_late from pg_temp.quest_pool p
        where p.rarity = 'uncommon' and not p.used and p.owner_id <> v_rare.owner_id
          and (v_theme.id is null or p.category = v_theme.id)
          and p.time_zone = v_rare.time_zone
          and extensions.st_dwithin(p.geog, v_rare.geog, v_tier)
          and bit_count(p.hours & v_rare.hours) >= v_min_hours
        order by extensions.st_distance(p.geog, v_rare.geog), p.created_at, p.id
        limit 1;
        continue when not found;

        v_mask := v_rare.hours & v_late.hours;
        v_owners := array[v_rare.owner_id, v_late.owner_id];

        -- Perhaps a second uncommon stage before it, and a common one before that.
        select * into v_early from pg_temp.quest_pool p
        where p.rarity = 'uncommon' and not p.used and p.id <> v_late.id and p.owner_id <> all (v_owners)
          and (v_theme.id is null or p.category = v_theme.id)
          and p.time_zone = v_rare.time_zone
          and extensions.st_dwithin(p.geog, v_late.geog, v_tier)
          and bit_count(p.hours & v_mask) >= v_min_hours
        order by extensions.st_distance(p.geog, v_late.geog), p.created_at, p.id
        limit 1;
        v_has_early := found;

        if v_has_early then
          select * into v_first from pg_temp.quest_pool p
          where p.rarity = 'common' and not p.used and p.owner_id <> all (v_owners || v_early.owner_id)
            and (v_theme.id is null or p.category = v_theme.id)
            and p.time_zone = v_rare.time_zone
            and extensions.st_dwithin(p.geog, v_early.geog, v_tier)
            and bit_count(p.hours & v_mask & v_early.hours) >= v_min_hours
          order by extensions.st_distance(p.geog, v_early.geog), p.created_at, p.id
          limit 1;
          v_has_early := found;
        end if;

        if v_has_early then
          v_mask := v_mask & v_early.hours & v_first.hours;
        else
          -- Three stages: a common offer straight before the uncommon one.
          select * into v_first from pg_temp.quest_pool p
          where p.rarity = 'common' and not p.used and p.owner_id <> all (v_owners)
            and (v_theme.id is null or p.category = v_theme.id)
            and p.time_zone = v_rare.time_zone
            and extensions.st_dwithin(p.geog, v_late.geog, v_tier)
            and bit_count(p.hours & v_mask) >= v_min_hours
          order by extensions.st_distance(p.geog, v_late.geog), p.created_at, p.id
          limit 1;
          continue when not found;
          v_mask := v_mask & v_first.hours;
        end if;

        insert into public.quests (name, theme, stage_count, max_leg_m, time_zone, open_hours)
        values (
          left(
            coalesce(v_theme.theme || ': ', '') ||
            coalesce((select p.display_name from public.profiles p where p.id = v_first.owner_id), 'Someone')
            || ' to ' ||
            coalesce((select p.display_name from public.profiles p where p.id = v_rare.owner_id), 'someone'),
            90),
          v_theme.id,
          case when v_has_early then 4 else 3 end,
          v_tier, v_rare.time_zone, v_mask)
        returning id into v_quest;

        insert into public.quest_stages (quest_id, position, drop_id, rarity) values (v_quest, 1, v_first.id, 'common');
        if v_has_early then
          insert into public.quest_stages (quest_id, position, drop_id, rarity) values
            (v_quest, 2, v_early.id, 'uncommon'), (v_quest, 3, v_late.id, 'uncommon'), (v_quest, 4, v_rare.id, 'rare');
          update pg_temp.quest_pool set used = true where id in (v_first.id, v_early.id, v_late.id, v_rare.id);
        else
          insert into public.quest_stages (quest_id, position, drop_id, rarity) values
            (v_quest, 2, v_late.id, 'uncommon'), (v_quest, 3, v_rare.id, 'rare');
          update pg_temp.quest_pool set used = true where id in (v_first.id, v_late.id, v_rare.id);
        end if;
        v_built := v_built + 1;
      end loop;
    end loop;
  end loop;

  drop table pg_temp.quest_pool;
  return v_built;
end;
$$;

-- Quests now say their theme.
create or replace function public.quest_to_json(q public.quests)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'id', q.id,
    'name', q.name,
    'theme', q.theme,
    'themeName', (select c.theme from public.offer_categories c where c.id = q.theme),
    'status', q.status,
    'stageCount', q.stage_count,
    'maxLegMetres', q.max_leg_m,
    'timeZone', q.time_zone,
    'openHours', q.open_hours::text,
    'openNow', q.status = 'active' and not exists (
      select 1 from public.quest_stages s join public.drops d on d.id = s.drop_id
      where s.quest_id = q.id and not public.drop_is_open(d)),
    'builtAt', q.built_at,
    'stages', coalesce((
      select jsonb_agg(jsonb_build_object(
          'position', s.position,
          'rarity', s.rarity,
          'drop', case when d.review = 'approved' and not d.paused
                         and not exists (select 1 from public.profiles p where p.id = d.owner_id and p.strikes >= 3)
                       then public.drop_to_json(d) end)
        order by s.position)
      from public.quest_stages s join public.drops d on d.id = s.drop_id
      where s.quest_id = q.id), '[]'::jsonb));
$$;
