-- Background jobs once a day, all in the same minute (09:00 UTC, 3 am in Austin).
--
-- pg_cron writes a log row for every run, and the project archives its WAL with
-- archive_timeout = 120 s. So any write in a two-minute window makes Postgres write out
-- a whole 16 MB WAL segment, however small the change. Jobs every 3, 10 and 15 minutes
-- cost about 25 segments an hour and used up the small compute's Disk IO budget.
-- Running everything together once a day costs one segment a day.
--
-- What it costs to wait: dropped items go back to their owners, open trades expire and
-- quests are rebuilt up to a day late.
-- The event finder stays paused: found-daily is off, and found-tick only marks ended
-- events expired. To find events again, set found-tick back to '*/3 * * * *' and turn
-- found-daily on.

select cron.alter_job(job_id := (select jobid from cron.job where jobname = 'build-quests'), schedule := '0 9 * * *');
select cron.alter_job(job_id := (select jobid from cron.job where jobname = 'play-upkeep'), schedule := '0 9 * * *');
select cron.alter_job(job_id := (select jobid from cron.job where jobname = 'found-tick'), schedule := '0 9 * * *', active := true);
select cron.alter_job(job_id := (select jobid from cron.job where jobname = 'found-daily'), active := false);
