-- Permission tests for people and drops.
--
-- Run the whole file as one query, as the Supabase SQL editor and the
-- connector's execute_sql do. It runs as a single transaction, so if anything
-- fails nothing is kept. At the end it deletes its test accounts (and with
-- them their drops) and its scratch schema, then lists every test; all should
-- say passed = true.
--
-- Test accounts use example.invalid addresses and spots in the Atlantic.
-- Each "reset role" also clears the signed-in user, so the statements after it
-- run the way the SQL editor does: as the database owner, with no user.

-- Results go in a scratch schema that the clean-up at the end removes.
create schema perm_test;
create table perm_test.results (n serial, test text, passed boolean, detail text);
grant usage on schema perm_test to anon, authenticated;
grant insert, select on perm_test.results to anon, authenticated;
grant usage on sequence perm_test.results_n_seq to anon, authenticated;

-- Four test accounts: a, b and d have finished profiles, c hasn't, s is staff.
insert into auth.users (id, aud, role, email) values
  ('aaaaaaaa-0000-4000-8000-000000000001', 'authenticated', 'authenticated', 'a@example.invalid'),
  ('bbbbbbbb-0000-4000-8000-000000000002', 'authenticated', 'authenticated', 'b@example.invalid'),
  ('cccccccc-0000-4000-8000-000000000003', 'authenticated', 'authenticated', 'c@example.invalid'),
  ('dddddddd-0000-4000-8000-000000000004', 'authenticated', 'authenticated', 'd@example.invalid'),
  ('eeeeeeee-0000-4000-8000-000000000005', 'authenticated', 'authenticated', 's@example.invalid');

insert into perm_test.results (test, passed, detail)
select 'a profile is created with each account', count(*) = 5, count(*)::text
from public.profiles where id in (
  'aaaaaaaa-0000-4000-8000-000000000001', 'bbbbbbbb-0000-4000-8000-000000000002',
  'cccccccc-0000-4000-8000-000000000003', 'dddddddd-0000-4000-8000-000000000004',
  'eeeeeeee-0000-4000-8000-000000000005');

update public.profiles set display_name = 'Tester', adult_confirmed_at = now()
where id in ('aaaaaaaa-0000-4000-8000-000000000001', 'bbbbbbbb-0000-4000-8000-000000000002',
             'dddddddd-0000-4000-8000-000000000004', 'eeeeeeee-0000-4000-8000-000000000005');
update public.profiles set is_staff = true where id = 'eeeeeeee-0000-4000-8000-000000000005';

-- A drop as the app sends it. Each test changes what it needs.
select set_config('t.drop', '{
  "type": "object", "title": "Test drop", "description": "", "objectId": "gift",
  "placement": {"lat": 45.0, "lng": -30.0, "height": 2, "size": 4, "turn": 0},
  "timeZone": "UTC", "timing": {"kind": "always"}, "audience": "everyone"
}', false);

-- ===== Visitors ===========================================================
set role anon;

do $$ begin
  begin
    perform 1 from public.drops limit 1;
    insert into perm_test.results (test, passed, detail) values ('visitors cannot read the drops table', false, 'select worked');
  exception when insufficient_privilege then
    insert into perm_test.results (test, passed, detail) values ('visitors cannot read the drops table', true, sqlerrm);
  end;

  begin
    perform 1 from public.profiles limit 1;
    insert into perm_test.results (test, passed, detail) values ('visitors cannot read profiles', false, 'select worked');
  exception when insufficient_privilege then
    insert into perm_test.results (test, passed, detail) values ('visitors cannot read profiles', true, sqlerrm);
  end;

  begin
    perform public.save_drop(current_setting('t.drop')::jsonb);
    insert into perm_test.results (test, passed, detail) values ('visitors cannot save a drop', false, 'save worked');
  exception when insufficient_privilege then
    insert into perm_test.results (test, passed, detail) values ('visitors cannot save a drop', true, sqlerrm);
  end;

  begin
    perform public.public_drops_in_bounds(-30.01, 44.99, -29.99, 45.01);
    perform public.search_public_drops('test');
    insert into perm_test.results (test, passed, detail) values ('visitors can read the public map and search', true, null);
  exception when others then
    insert into perm_test.results (test, passed, detail) values ('visitors can read the public map and search', false, sqlerrm);
  end;
end $$;

reset role;
select set_config('request.jwt.claims', '', false);

-- ===== Person A: a new account ===========================================
set role authenticated;
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-4000-8000-000000000001","role":"authenticated"}', false);

do $$
declare v_id text; v_review text;
begin
  v_id := public.save_drop(current_setting('t.drop')::jsonb);
  perform set_config('t.a1', v_id, false);
  select review into v_review from public.drops where id = v_id;
  insert into perm_test.results (test, passed, detail) values ('a new account''s first drop goes to review', v_review = 'pending', v_review);

  begin
    update public.drops set review = 'approved' where id = v_id;
    insert into perm_test.results (test, passed, detail) values ('owners cannot approve their own drop', false, 'update worked');
  exception when insufficient_privilege then
    insert into perm_test.results (test, passed, detail) values ('owners cannot approve their own drop', true, sqlerrm);
  end;

  begin
    update public.profiles set is_staff = true where id = 'aaaaaaaa-0000-4000-8000-000000000001';
    insert into perm_test.results (test, passed, detail) values ('people cannot make themselves staff', false, 'update worked');
  exception when insufficient_privilege then
    insert into perm_test.results (test, passed, detail) values ('people cannot make themselves staff', true, sqlerrm);
  end;

  begin
    perform public.save_drop(jsonb_set(current_setting('t.drop')::jsonb, '{placement,size}', '31'));
    insert into perm_test.results (test, passed, detail) values ('size is capped at 30 m', false, 'save worked');
  exception when check_violation then
    insert into perm_test.results (test, passed, detail) values ('size is capped at 30 m', true, sqlerrm);
  end;

  begin
    perform public.save_drop(jsonb_set(current_setting('t.drop')::jsonb, '{placement,height}', '101'));
    insert into perm_test.results (test, passed, detail) values ('height is capped at 100 m', false, 'save worked');
  exception when check_violation then
    insert into perm_test.results (test, passed, detail) values ('height is capped at 100 m', true, sqlerrm);
  end;

  begin
    perform public.save_drop(jsonb_set(current_setting('t.drop')::jsonb, '{title}', to_jsonb(repeat('x', 71))));
    insert into perm_test.results (test, passed, detail) values ('titles are capped at 70 characters', false, 'save worked');
  exception when check_violation then
    insert into perm_test.results (test, passed, detail) values ('titles are capped at 70 characters', true, sqlerrm);
  end;

  begin
    perform public.save_drop(jsonb_set(current_setting('t.drop')::jsonb, '{timing}', '{"kind":"weekly","blocks":[]}'));
    insert into perm_test.results (test, passed, detail) values ('weekly hours cannot be empty', false, 'save worked');
  exception when raise_exception then
    insert into perm_test.results (test, passed, detail) values ('weekly hours cannot be empty', sqlerrm = 'schedule_empty', sqlerrm);
  end;

  begin
    perform public.save_drop(jsonb_set(current_setting('t.drop')::jsonb, '{timing}',
      '{"kind":"weekly","blocks":[{"days":[1],"start":"18:00","end":"09:00"}]}'));
    insert into perm_test.results (test, passed, detail) values ('weekly hours end after they start', false, 'save worked');
  exception when check_violation then
    insert into perm_test.results (test, passed, detail) values ('weekly hours end after they start', true, sqlerrm);
  end;

  begin
    perform public.save_drop(jsonb_set(current_setting('t.drop')::jsonb, '{objectId}', '"not-in-library"'));
    insert into perm_test.results (test, passed, detail) values ('drops must use a ready-made object', false, 'save worked');
  exception when foreign_key_violation then
    insert into perm_test.results (test, passed, detail) values ('drops must use a ready-made object', true, sqlerrm);
  end;
end $$;

reset role;
select set_config('request.jwt.claims', '', false);

-- Unapproved drops stay off the public map and their page.
set role anon;
do $$ begin
  insert into perm_test.results (test, passed, detail)
  values ('drops in review are not public', public.public_drop(current_setting('t.a1')) is null, null);
end $$;
reset role;
select set_config('request.jwt.claims', '', false);

-- A moderator approves it (as the SQL editor would).
update public.drops set review = 'approved' where id = current_setting('t.a1');

set role anon;
do $$ begin
  insert into perm_test.results (test, passed, detail)
  values ('approved drops are public', public.public_drop(current_setting('t.a1')) is not null, null);
  insert into perm_test.results (test, passed, detail)
  values ('approved drops are on the map',
          exists (select 1 from public.public_drops_in_bounds(-30.01, 44.99, -29.99, 45.01) j
                  where j ->> 'id' = current_setting('t.a1')), null);
  insert into perm_test.results (test, passed, detail)
  values ('search finds approved drops by title',
          exists (select 1 from public.search_public_drops('test drop', 20) j
                  where j ->> 'id' = current_setting('t.a1')), null);
end $$;
reset role;
select set_config('request.jwt.claims', '', false);

set role authenticated;
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-4000-8000-000000000001","role":"authenticated"}', false);

do $$
declare v_id text; v_review text;
begin
  v_id := public.save_drop(current_setting('t.drop')::jsonb);
  select review into v_review from public.drops where id = v_id;
  insert into perm_test.results (test, passed, detail) values ('after one approval, new drops go live', v_review = 'approved', v_review);

  update public.drops set paused = true where id = v_id;
  perform set_config('t.a_paused', v_id, false);

  v_id := public.save_drop(jsonb_set(current_setting('t.drop')::jsonb, '{audience}', '"link"'));
  perform set_config('t.a_link', v_id, false);

  v_id := public.save_drop(jsonb_set(current_setting('t.drop')::jsonb, '{timing}',
    '{"kind":"weekly","blocks":[{"days":[0,1,2,3,4,5,6],"start":"00:00","end":"23:59"}]}'));
  perform set_config('t.a_open', v_id, false);

  v_id := public.save_drop(jsonb_set(current_setting('t.drop')::jsonb, '{timing}',
    '{"kind":"once","start":"2000-01-01T08:00","end":"2000-01-01T20:00"}'));
  perform set_config('t.a_over', v_id, false);

  begin
    perform public.save_drop(current_setting('t.drop')::jsonb);
    insert into perm_test.results (test, passed, detail) values ('five new drops a day at most', false, 'sixth save worked');
  exception when raise_exception then
    insert into perm_test.results (test, passed, detail) values ('five new drops a day at most', sqlerrm = 'limit_daily', sqlerrm);
  end;

  insert into perm_test.results (test, passed, detail)
  select 'people see all of their own drops', count(*) = 5, count(*)::text from public.my_drops();
end $$;

reset role;
select set_config('request.jwt.claims', '', false);

set role anon;
do $$ begin
  insert into perm_test.results (test, passed, detail)
  values ('paused drops are not public', public.public_drop(current_setting('t.a_paused')) is null, null);
  insert into perm_test.results (test, passed, detail)
  values ('link-only drops open from their link', public.public_drop(current_setting('t.a_link')) is not null, null);
  insert into perm_test.results (test, passed, detail)
  values ('link-only drops stay off the map',
          not exists (select 1 from public.public_drops_in_bounds(-30.01, 44.99, -29.99, 45.01) j
                      where j ->> 'id' = current_setting('t.a_link')), null);
  insert into perm_test.results (test, passed, detail)
  values ('drops within their weekly hours are on the map',
          exists (select 1 from public.public_drops_in_bounds(-30.01, 44.99, -29.99, 45.01) j
                  where j ->> 'id' = current_setting('t.a_open')), null);
  insert into perm_test.results (test, passed, detail)
  values ('drops past their one time are off the map',
          not exists (select 1 from public.public_drops_in_bounds(-30.01, 44.99, -29.99, 45.01) j
                      where j ->> 'id' = current_setting('t.a_over')), null);
end $$;
reset role;
select set_config('request.jwt.claims', '', false);

-- ===== Person B: someone else =============================================
set role authenticated;
select set_config('request.jwt.claims', '{"sub":"bbbbbbbb-0000-4000-8000-000000000002","role":"authenticated"}', false);

do $$
declare v_count int;
begin
  select count(*) into v_count from public.drops where id = current_setting('t.a1');
  insert into perm_test.results (test, passed, detail) values ('people cannot read others'' drops directly', v_count = 0, v_count::text);

  update public.drops set title = 'Taken over' where id = current_setting('t.a1');
  get diagnostics v_count = row_count;
  insert into perm_test.results (test, passed, detail) values ('people cannot change others'' drops', v_count = 0, v_count::text);

  delete from public.drops where id = current_setting('t.a1');
  get diagnostics v_count = row_count;
  insert into perm_test.results (test, passed, detail) values ('people cannot delete others'' drops', v_count = 0, v_count::text);

  begin
    perform public.save_drop(jsonb_set(current_setting('t.drop')::jsonb, '{id}', to_jsonb(current_setting('t.a1'))));
    insert into perm_test.results (test, passed, detail) values ('people cannot save over others'' drops', false, 'save worked');
  exception when raise_exception then
    insert into perm_test.results (test, passed, detail) values ('people cannot save over others'' drops', sqlerrm = 'not_found', sqlerrm);
  end;

  begin
    insert into public.schedule_blocks (drop_id, days, start_time, end_time)
    values (current_setting('t.a1'), '{1}', '09:00', '10:00');
    insert into perm_test.results (test, passed, detail) values ('people cannot add hours to others'' drops', false, 'insert worked');
  exception when insufficient_privilege then
    insert into perm_test.results (test, passed, detail) values ('people cannot add hours to others'' drops', true, sqlerrm);
  end;

  insert into perm_test.results (test, passed, detail)
  select 'people see only their own drops', count(*) = 0, count(*)::text from public.my_drops();
end $$;

reset role;
select set_config('request.jwt.claims', '', false);

-- B already has ten drops from earlier days.
insert into public.drops (owner_id, type, title, object_id, lat, lng, time_zone, review, created_at)
select 'bbbbbbbb-0000-4000-8000-000000000002', 'object', 'Old drop ' || i, 'star', 45.2, -30.2, 'UTC', 'approved',
       now() - interval '3 days'
from generate_series(1, 10) i;

set role authenticated;
select set_config('request.jwt.claims', '{"sub":"bbbbbbbb-0000-4000-8000-000000000002","role":"authenticated"}', false);
do $$ begin
  begin
    perform public.save_drop(current_setting('t.drop')::jsonb);
    insert into perm_test.results (test, passed, detail) values ('ten drops at a time at most', false, 'save worked');
  exception when raise_exception then
    insert into perm_test.results (test, passed, detail) values ('ten drops at a time at most', sqlerrm = 'limit_total', sqlerrm);
  end;
end $$;
reset role;
select set_config('request.jwt.claims', '', false);

-- ===== Person C: hasn't given a name or confirmed their age ===============
set role authenticated;
select set_config('request.jwt.claims', '{"sub":"cccccccc-0000-4000-8000-000000000003","role":"authenticated"}', false);
do $$ begin
  begin
    perform public.save_drop(current_setting('t.drop')::jsonb);
    insert into perm_test.results (test, passed, detail) values ('publishing needs a name and an age check', false, 'save worked');
  exception when raise_exception then
    insert into perm_test.results (test, passed, detail) values ('publishing needs a name and an age check', sqlerrm = 'profile_incomplete', sqlerrm);
  end;
end $$;
reset role;
select set_config('request.jwt.claims', '', false);

-- ===== Crowding: a spot that already has 20 public drops ==================
insert into public.drops (owner_id, type, title, object_id, lat, lng, time_zone, review)
select 'eeeeeeee-0000-4000-8000-000000000005', 'object', 'Crowd ' || i, 'heart',
       46.0 + i * 0.00001, -30.0, 'UTC', 'approved'
from generate_series(1, 20) i;

set role authenticated;
select set_config('request.jwt.claims', '{"sub":"dddddddd-0000-4000-8000-000000000004","role":"authenticated"}', false);
do $$ begin
  begin
    perform public.save_drop(jsonb_set(current_setting('t.drop')::jsonb, '{placement,lat}', '46.0003'));
    insert into perm_test.results (test, passed, detail) values ('20 public drops within 100 m at most', false, 'save worked');
  exception when raise_exception then
    insert into perm_test.results (test, passed, detail) values ('20 public drops within 100 m at most', sqlerrm = 'limit_crowded', sqlerrm);
  end;

  begin
    perform set_config('t.d1', public.save_drop(jsonb_set(jsonb_set(current_setting('t.drop')::jsonb, '{placement,lat}', '46.0003'),
                                       '{audience}', '"link"')), false);
    insert into perm_test.results (test, passed, detail) values ('link-only drops don''t count toward crowding', true, null);
  exception when others then
    insert into perm_test.results (test, passed, detail) values ('link-only drops don''t count toward crowding', false, sqlerrm);
  end;
end $$;
reset role;
select set_config('request.jwt.claims', '', false);

-- ===== Staff are exempt from limits =======================================
set role authenticated;
select set_config('request.jwt.claims', '{"sub":"eeeeeeee-0000-4000-8000-000000000005","role":"authenticated"}', false);
do $$
declare v_id text; v_review text;
begin
  v_id := public.save_drop(jsonb_set(current_setting('t.drop')::jsonb, '{placement,lat}', '46.0003'));
  select review into v_review from public.drops where id = v_id;
  insert into perm_test.results (test, passed, detail) values ('staff drops skip limits and review', v_review = 'approved', v_review);
exception when others then
  insert into perm_test.results (test, passed, detail) values ('staff drops skip limits and review', false, sqlerrm);
end $$;
reset role;
select set_config('request.jwt.claims', '', false);

-- ===== The review queue ===================================================
-- D's link-only drop (t.d1) is D's first, so it's waiting for review.

set role authenticated;
select set_config('request.jwt.claims', '{"sub":"dddddddd-0000-4000-8000-000000000004","role":"authenticated"}', false);
do $$ begin
  begin
    perform public.review_queue();
    insert into perm_test.results (test, passed, detail) values ('only staff can see the review queue', false, 'queue returned');
  exception when raise_exception then
    insert into perm_test.results (test, passed, detail) values ('only staff can see the review queue', sqlerrm = 'not_staff', sqlerrm);
  end;

  begin
    perform public.review_drop(current_setting('t.d1'), 'approve');
    insert into perm_test.results (test, passed, detail) values ('only staff can approve', false, 'approve worked');
  exception when raise_exception then
    insert into perm_test.results (test, passed, detail) values ('only staff can approve', sqlerrm = 'not_staff', sqlerrm);
  end;

  begin
    perform 1 from public.moderation_events limit 1;
    insert into perm_test.results (test, passed, detail) values ('people cannot read the moderation log', false, 'select worked');
  exception when insufficient_privilege then
    insert into perm_test.results (test, passed, detail) values ('people cannot read the moderation log', true, sqlerrm);
  end;
end $$;
reset role;
select set_config('request.jwt.claims', '', false);

set role anon;
do $$ begin
  begin
    perform public.review_queue();
    insert into perm_test.results (test, passed, detail) values ('visitors cannot call the review functions', false, 'queue returned');
  exception when insufficient_privilege then
    insert into perm_test.results (test, passed, detail) values ('visitors cannot call the review functions', true, sqlerrm);
  end;
end $$;
reset role;
select set_config('request.jwt.claims', '', false);

set role authenticated;
select set_config('request.jwt.claims', '{"sub":"eeeeeeee-0000-4000-8000-000000000005","role":"authenticated"}', false);
do $$
declare v_json jsonb;
begin
  insert into perm_test.results (test, passed, detail)
  select 'staff see drops waiting for review',
         exists (select 1 from public.review_queue() j where j ->> 'id' = current_setting('t.d1')), null;

  begin
    perform public.review_drop(current_setting('t.d1'), 'reject');
    insert into perm_test.results (test, passed, detail) values ('a rejection needs a reason', false, 'reject worked');
  exception when raise_exception then
    insert into perm_test.results (test, passed, detail) values ('a rejection needs a reason', sqlerrm = 'reason_needed', sqlerrm);
  end;

  v_json := public.review_drop(current_setting('t.d1'), 'reject', 'It''s spam.');
  insert into perm_test.results (test, passed, detail)
  values ('staff can reject with a reason', v_json ->> 'review' = 'rejected' and v_json ->> 'reviewReason' = 'It''s spam.', v_json ->> 'review');

  begin
    delete from public.moderation_events;
    insert into perm_test.results (test, passed, detail) values ('nobody can delete the moderation log', false, 'delete worked');
  exception when insufficient_privilege then
    insert into perm_test.results (test, passed, detail) values ('nobody can delete the moderation log', true, sqlerrm);
  end;
end $$;
reset role;
select set_config('request.jwt.claims', '', false);

set role authenticated;
select set_config('request.jwt.claims', '{"sub":"dddddddd-0000-4000-8000-000000000004","role":"authenticated"}', false);
do $$
declare v_review text;
begin
  insert into perm_test.results (test, passed, detail)
  select 'owners see why a drop was rejected', j ->> 'reviewReason' = 'It''s spam.', j ->> 'reviewReason'
  from public.my_drops() j where j ->> 'id' = current_setting('t.d1');

  perform public.save_drop(jsonb_set(jsonb_set(jsonb_set(current_setting('t.drop')::jsonb, '{placement,lat}', '46.0003'),
                                     '{audience}', '"link"'), '{id}', to_jsonb(current_setting('t.d1'))));
  select review into v_review from public.drops where id = current_setting('t.d1');
  insert into perm_test.results (test, passed, detail)
  values ('editing a rejected drop sends it back for review', v_review = 'pending', v_review);
end $$;
reset role;
select set_config('request.jwt.claims', '', false);

set role authenticated;
select set_config('request.jwt.claims', '{"sub":"eeeeeeee-0000-4000-8000-000000000005","role":"authenticated"}', false);
do $$
declare v_json jsonb;
begin
  v_json := public.review_drop(current_setting('t.d1'), 'approve');
  insert into perm_test.results (test, passed, detail)
  values ('staff can approve', v_json ->> 'review' = 'approved' and v_json ->> 'reviewReason' is null, v_json ->> 'review');

  insert into perm_test.results (test, passed, detail)
  select 'every decision is logged', count(*) = 2, count(*)::text
  from public.review_history(100) j where j ->> 'dropId' = current_setting('t.d1');
end $$;
reset role;
select set_config('request.jwt.claims', '', false);

-- ===== Clean up, then show the results ====================================
drop table if exists pg_temp.perm_test_results;
create temp table perm_test_results as select * from perm_test.results;
delete from auth.users where id in (
  'aaaaaaaa-0000-4000-8000-000000000001', 'bbbbbbbb-0000-4000-8000-000000000002',
  'cccccccc-0000-4000-8000-000000000003', 'dddddddd-0000-4000-8000-000000000004',
  'eeeeeeee-0000-4000-8000-000000000005');
delete from public.moderation_events where drop_id = current_setting('t.d1');
drop schema perm_test cascade;

select n, passed, test, detail from perm_test_results order by n;
