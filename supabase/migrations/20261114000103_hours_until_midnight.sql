-- The time picker's last choice is 23:59, so weekly hours that end then run
-- to midnight instead of closing for the last minute of the day.
create or replace function public.drop_is_open(d public.drops)
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
        and ((now() at time zone d.time_zone)::time < b.end_time or b.end_time >= time '23:59')
    )
  end;
$$;

revoke execute on function public.drop_is_open(public.drops) from public, anon, authenticated;
