-- The event finder twice a day, morning and evening, with a tick only while it works.
--
-- Commit 6c053ff put every background job on one daily schedule because pg_cron logs a
-- row per run and the project archives its WAL every 120 s: any write in a two-minute
-- window costs a whole 16 MB segment, and a job every 3 minutes ate the small compute's
-- Disk IO budget. This brings the finder back on a 12-hour cadence without that bill:
-- found-daily queues a run at 14:00 and 02:00, and found-tick wakes the Edge Function
-- every ten minutes during those two hours only — 12 ticks a day, not 480.
--
-- The schedules are UTC, which is 6 AM and 6 PM PST. They drift an hour, to 7 AM and
-- 7 PM, when PDT starts; an hour either way doesn't matter to a search.
--
-- build-quests and play-upkeep are untouched, still 09:00 UTC once a day.
--
-- How much one run may add is capped in the Edge Function, not here: see
-- MAX_EVENTS_PER_RUN in supabase/functions/find-events/cap.ts.

-- Only the guard changes: a run every 12 hours has to get past it, and at 20 hours the
-- morning run would swallow the evening one. Ten hours still stops a double run if the
-- job fires twice, or if staff ask for one just before it.
create or replace function private.found_daily()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.found_runs (area_id)
  select a.id from public.found_areas a
  where a.active
    and not exists (select 1 from public.found_runs r
                    where r.area_id = a.id and r.created_at > now() - interval '10 hours');
  perform private.found_tick();
end;
$$;

-- create or replace keeps the privileges the function already had; said again so a
-- replace can never be what opens it up.
revoke execute on function private.found_daily() from public, anon, authenticated;

select cron.alter_job(job_id := (select jobid from cron.job where jobname = 'found-daily'),
                      schedule := '0 14,2 * * *', active := true);
select cron.alter_job(job_id := (select jobid from cron.job where jobname = 'found-tick'),
                      schedule := '*/10 14,2 * * *');
