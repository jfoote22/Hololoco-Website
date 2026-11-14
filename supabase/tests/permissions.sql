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

-- ===== Reports ============================================================
-- Visitors report from a connection; set_config stands in for the address.

set role anon;
do $$ begin
  begin
    perform 1 from public.reports limit 1;
    insert into perm_test.results (test, passed, detail) values ('visitors cannot read reports', false, 'select worked');
  exception when insufficient_privilege then
    insert into perm_test.results (test, passed, detail) values ('visitors cannot read reports', true, sqlerrm);
  end;

  begin
    perform public.file_report(current_setting('t.a1'), 'other');
    insert into perm_test.results (test, passed, detail) values ('"something else" needs details', false, 'filed');
  exception when raise_exception then
    insert into perm_test.results (test, passed, detail) values ('"something else" needs details', sqlerrm = 'details_needed', sqlerrm);
  end;

  begin
    perform public.file_report(current_setting('t.a1'), 'copyright', 'My photo');
    insert into perm_test.results (test, passed, detail) values ('copyright reports need a contact', false, 'filed');
  exception when raise_exception then
    insert into perm_test.results (test, passed, detail) values ('copyright reports need a contact', sqlerrm = 'contact_needed', sqlerrm);
  end;

  begin
    perform public.file_report(current_setting('t.a_paused'), 'spam');
    insert into perm_test.results (test, passed, detail) values ('only visible drops can be reported', false, 'filed');
  exception when raise_exception then
    insert into perm_test.results (test, passed, detail) values ('only visible drops can be reported', sqlerrm = 'not_found', sqlerrm);
  end;
end $$;

select set_config('request.headers', '{"x-forwarded-for":"10.0.0.1"}', false);
do $$
declare v_json jsonb;
begin
  v_json := public.file_report(current_setting('t.a1'), 'spam');
  insert into perm_test.results (test, passed, detail)
  values ('visitors can report a drop', (v_json ->> 'filed')::boolean and not (v_json ->> 'hidden')::boolean, v_json::text);
  perform public.file_report(current_setting('t.a1'), 'spam');
end $$;
select set_config('request.headers', '{"x-forwarded-for":"10.0.0.2"}', false);
select public.file_report(current_setting('t.a1'), 'spam');
reset role;
select set_config('request.jwt.claims', '', false);

insert into perm_test.results (test, passed, detail)
select 'a repeat report from the same person is ignored', count(*) = 2, count(*)::text
from public.reports where drop_id = current_setting('t.a1');
insert into perm_test.results (test, passed, detail)
select 'two reports don''t hide a drop', review = 'approved', review
from public.drops where id = current_setting('t.a1');
insert into perm_test.results (test, passed, detail)
select 'the reporter''s address isn''t stored', not exists (select 1 from public.reports where reporter_key like '%10.0.0%'), null;

set role anon;
select set_config('request.headers', '{"x-forwarded-for":"10.0.0.3"}', false);
do $$
declare v_json jsonb;
begin
  v_json := public.file_report(current_setting('t.a1'), 'offensive');
  insert into perm_test.results (test, passed, detail)
  values ('reports from three people hide a drop', (v_json ->> 'hidden')::boolean
          and public.public_drop(current_setting('t.a1')) is null, v_json::text);
end $$;
select set_config('request.headers', '{"x-forwarded-for":"10.0.0.4"}', false);
do $$
declare v_json jsonb;
begin
  v_json := public.file_report(current_setting('t.a_open'), 'unsafe', 'Blocks the fire exit.');
  insert into perm_test.results (test, passed, detail)
  values ('a serious report hides a drop at once', (v_json ->> 'hidden')::boolean
          and public.public_drop(current_setting('t.a_open')) is null, v_json::text);
end $$;

-- Removal requests not about one drop.
do $$ begin
  begin
    perform public.file_report(null, 'property', 'The note at 12 Main St is on my house.');
    insert into perm_test.results (test, passed, detail) values ('removal requests need a contact', false, 'filed');
  exception when raise_exception then
    insert into perm_test.results (test, passed, detail) values ('removal requests need a contact', sqlerrm = 'contact_needed', sqlerrm);
  end;
  perform public.file_report(null, 'property', 'The note at 12 Main St is on my house.', 'owner@example.invalid');
  insert into perm_test.results (test, passed, detail) values ('anyone can ask for a removal without an account', true, null);
exception when others then
  insert into perm_test.results (test, passed, detail) values ('anyone can ask for a removal without an account', false, sqlerrm);
end $$;

select set_config('request.headers', '{"x-forwarded-for":"10.0.0.9"}', false);
do $$ begin
  for i in 1..10 loop
    perform public.file_report(null, 'property', 'Request ' || i, 'owner@example.invalid');
  end loop;
  begin
    perform public.file_report(null, 'property', 'Request 11', 'owner@example.invalid');
    insert into perm_test.results (test, passed, detail) values ('ten reports a day per person at most', false, 'eleventh filed');
  exception when raise_exception then
    insert into perm_test.results (test, passed, detail) values ('ten reports a day per person at most', sqlerrm = 'limit_reports', sqlerrm);
  end;
end $$;
reset role;
select set_config('request.jwt.claims', '', false);
select set_config('request.headers', '', false);

insert into perm_test.results (test, passed, detail)
select 'hiding a drop is logged', count(*) = 2, count(*)::text
from public.moderation_events where action = 'hide' and drop_id in (current_setting('t.a1'), current_setting('t.a_open'));

set role authenticated;
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-4000-8000-000000000001","role":"authenticated"}', false);
do $$ begin
  insert into perm_test.results (test, passed, detail)
  select 'owners see their drop is hidden for a report', (j ->> 'hiddenForReport')::boolean, j ->> 'hiddenForReport'
  from public.my_drops() j where j ->> 'id' = current_setting('t.a1');
end $$;
reset role;
select set_config('request.jwt.claims', '', false);

set role authenticated;
select set_config('request.jwt.claims', '{"sub":"dddddddd-0000-4000-8000-000000000004","role":"authenticated"}', false);
do $$ begin
  begin
    perform public.review_reports();
    insert into perm_test.results (test, passed, detail) values ('only staff can read reports', false, 'reports returned');
  exception when raise_exception then
    insert into perm_test.results (test, passed, detail) values ('only staff can read reports', sqlerrm = 'not_staff', sqlerrm);
  end;
end $$;
reset role;
select set_config('request.jwt.claims', '', false);

set role authenticated;
select set_config('request.jwt.claims', '{"sub":"eeeeeeee-0000-4000-8000-000000000005","role":"authenticated"}', false);
do $$
declare v_request bigint;
begin
  insert into perm_test.results (test, passed, detail)
  select 'staff see reported drops with their reports',
         exists (select 1 from public.review_reports() j
                 where j -> 'drop' ->> 'id' = current_setting('t.a1') and jsonb_array_length(j -> 'reports') = 3), null;
  insert into perm_test.results (test, passed, detail)
  select 'reported drops wait in reports, not the queue',
         not exists (select 1 from public.review_queue() j where j ->> 'id' = current_setting('t.a1')), null;

  perform public.review_drop(current_setting('t.a1'), 'approve');
  perform public.review_drop(current_setting('t.a_open'), 'reject', 'It blocks a fire exit.');

  select (j -> 'reports' -> 0 ->> 'id')::bigint into v_request
  from public.review_reports() j
  where j ->> 'kind' = 'request' and j -> 'reports' -> 0 ->> 'details' = 'The note at 12 Main St is on my house.'
  limit 1;
  perform public.close_report(v_request, 'resolved', 'Removed it.');
  insert into perm_test.results (test, passed, detail)
  select 'staff can close a removal request',
         not exists (select 1 from public.review_reports() j where (j -> 'reports' -> 0 ->> 'id')::bigint = v_request), null;
end $$;
reset role;
select set_config('request.jwt.claims', '', false);

insert into perm_test.results (test, passed, detail)
select 'keeping a drop dismisses its reports and shows it again',
       (select count(*) from public.reports where drop_id = current_setting('t.a1') and status = 'dismissed') = 3
       and (select review from public.drops where id = current_setting('t.a1')) = 'approved', null;
insert into perm_test.results (test, passed, detail)
select 'taking a drop down resolves its reports',
       (select count(*) from public.reports where drop_id = current_setting('t.a_open') and status = 'resolved') = 1
       and (select review from public.drops where id = current_setting('t.a_open')) = 'rejected', null;

-- ===== Uploads ============================================================
-- F already has an approved drop, so ready-made objects would go live at once.
-- Upload rows are made here as the database owner, since the files themselves
-- can only be uploaded through Supabase Storage.

insert into auth.users (id, aud, role, email) values
  ('ffffffff-0000-4000-8000-000000000006', 'authenticated', 'authenticated', 'f@example.invalid');
update public.profiles set display_name = 'Tester', adult_confirmed_at = now()
where id = 'ffffffff-0000-4000-8000-000000000006';
insert into public.drops (owner_id, type, title, object_id, lat, lng, time_zone, review)
values ('ffffffff-0000-4000-8000-000000000006', 'object', 'Earlier drop', 'gift', 47.0, -30.0, 'UTC', 'approved');

insert into public.assets (id, owner_id, kind, source_format, triangles, model_path, thumbnail_path)
values
  ('0f0f0f0f-0000-4000-8000-0000000000f1', 'ffffffff-0000-4000-8000-000000000006', 'model', 'fbx', 9000,
   'ffffffff-0000-4000-8000-000000000006/0f0f0f0f-0000-4000-8000-0000000000f1/model.glb',
   'ffffffff-0000-4000-8000-000000000006/0f0f0f0f-0000-4000-8000-0000000000f1/thumbnail.png'),
  ('0d0d0d0d-0000-4000-8000-0000000000d1', 'dddddddd-0000-4000-8000-000000000004', 'model', 'glb', 500,
   'dddddddd-0000-4000-8000-000000000004/0d0d0d0d-0000-4000-8000-0000000000d1/model.glb',
   'dddddddd-0000-4000-8000-000000000004/0d0d0d0d-0000-4000-8000-0000000000d1/thumbnail.png');

do $$ begin
  begin
    insert into public.assets (id, owner_id, kind, source_format, model_path, thumbnail_path)
    values ('0e0e0e0e-0000-4000-8000-0000000000e1', 'ffffffff-0000-4000-8000-000000000006', 'model', 'glb',
            'dddddddd-0000-4000-8000-000000000004/x/model.glb', 'dddddddd-0000-4000-8000-000000000004/x/thumbnail.png');
    insert into perm_test.results (test, passed, detail) values ('uploads stay in their owner''s folder', false, 'insert worked');
  exception when check_violation then
    insert into perm_test.results (test, passed, detail) values ('uploads stay in their owner''s folder', true, sqlerrm);
  end;
end $$;

set role anon;
do $$ begin
  begin
    perform 1 from public.assets limit 1;
    insert into perm_test.results (test, passed, detail) values ('visitors cannot read uploads', false, 'select worked');
  exception when insufficient_privilege then
    insert into perm_test.results (test, passed, detail) values ('visitors cannot read uploads', true, sqlerrm);
  end;
end $$;
reset role;
select set_config('request.jwt.claims', '', false);

set role authenticated;
select set_config('request.jwt.claims', '{"sub":"ffffffff-0000-4000-8000-000000000006","role":"authenticated"}', false);
do $$
declare v_id text; v_review text; v_json jsonb;
begin
  begin
    insert into public.assets (id, kind, source_format, model_path, thumbnail_path)
    values ('0e0e0e0e-0000-4000-8000-0000000000e2', 'model', 'glb',
            'ffffffff-0000-4000-8000-000000000006/0e0e0e0e-0000-4000-8000-0000000000e2/model.glb',
            'ffffffff-0000-4000-8000-000000000006/0e0e0e0e-0000-4000-8000-0000000000e2/thumbnail.png');
    insert into perm_test.results (test, passed, detail) values ('an upload needs its files uploaded first', false, 'insert worked');
  exception when raise_exception then
    insert into perm_test.results (test, passed, detail) values ('an upload needs its files uploaded first', sqlerrm = 'upload_missing', sqlerrm);
  end;

  begin
    update public.assets set status = 'approved' where id = '0f0f0f0f-0000-4000-8000-0000000000f1';
    insert into perm_test.results (test, passed, detail) values ('people cannot approve their own upload', false, 'update worked');
  exception when insufficient_privilege then
    insert into perm_test.results (test, passed, detail) values ('people cannot approve their own upload', true, sqlerrm);
  end;

  v_id := public.save_drop(jsonb_set(jsonb_set(jsonb_set(current_setting('t.drop')::jsonb, '{placement,lat}', '47.001'),
                                     '{objectId}', 'null'), '{assetId}', '"0f0f0f0f-0000-4000-8000-0000000000f1"'));
  perform set_config('t.f1', v_id, false);
  select review into v_review from public.drops where id = v_id;
  insert into perm_test.results (test, passed, detail)
  values ('a drop with an upload always waits for review', v_review = 'pending', v_review);

  begin
    perform public.save_drop(jsonb_set(jsonb_set(current_setting('t.drop')::jsonb, '{objectId}', 'null'),
                                       '{assetId}', '"0d0d0d0d-0000-4000-8000-0000000000d1"'));
    insert into perm_test.results (test, passed, detail) values ('people cannot use someone else''s upload', false, 'save worked');
  exception when raise_exception then
    insert into perm_test.results (test, passed, detail) values ('people cannot use someone else''s upload', sqlerrm = 'asset_not_found', sqlerrm);
  end;

  begin
    perform public.publish_asset('0f0f0f0f-0000-4000-8000-0000000000f1');
    insert into perm_test.results (test, passed, detail) values ('only staff can publish an upload', false, 'published');
  exception when raise_exception then
    insert into perm_test.results (test, passed, detail) values ('only staff can publish an upload', sqlerrm = 'not_staff', sqlerrm);
  end;

  select j into v_json from public.my_drops() j where j ->> 'id' = current_setting('t.f1');
  insert into perm_test.results (test, passed, detail)
  values ('owners get their upload''s private files',
          v_json -> 'assetFiles' ->> 'model' like 'ffffffff-0000-4000-8000-000000000006/%' and v_json -> 'asset' ->> 'model' is null,
          v_json -> 'assetFiles' ->> 'model');
end $$;
reset role;
select set_config('request.jwt.claims', '', false);

set role authenticated;
select set_config('request.jwt.claims', '{"sub":"eeeeeeee-0000-4000-8000-000000000005","role":"authenticated"}', false);
do $$ begin
  insert into perm_test.results (test, passed, detail)
  select 'staff see uploads in the queue with their files',
         exists (select 1 from public.review_queue() j
                 where j ->> 'id' = current_setting('t.f1') and j -> 'assetFiles' ->> 'model' is not null), null;

  begin
    perform public.review_drop(current_setting('t.f1'), 'approve');
    insert into perm_test.results (test, passed, detail) values ('an upload is published before its drop is approved', false, 'approved');
  exception when raise_exception then
    insert into perm_test.results (test, passed, detail) values ('an upload is published before its drop is approved', sqlerrm = 'asset_not_published', sqlerrm);
  end;

  begin
    perform public.publish_asset('0f0f0f0f-0000-4000-8000-0000000000f1');
    insert into perm_test.results (test, passed, detail) values ('publishing needs the files copied to the public bucket', false, 'published');
  exception when raise_exception then
    insert into perm_test.results (test, passed, detail) values ('publishing needs the files copied to the public bucket', sqlerrm = 'not_copied', sqlerrm);
  end;

  perform public.review_drop(current_setting('t.f1'), 'reject', 'It''s spam.');
end $$;
reset role;
select set_config('request.jwt.claims', '', false);

-- Checked as the database owner, since staff can't read upload rows directly.
insert into perm_test.results (test, passed, detail)
values ('not approving a drop turns down its upload',
        coalesce((select status = 'rejected' and public_model_path is null
                  from public.assets where id = '0f0f0f0f-0000-4000-8000-0000000000f1'), false),
        (select status::text from public.assets where id = '0f0f0f0f-0000-4000-8000-0000000000f1'));

set role authenticated;
select set_config('request.jwt.claims', '{"sub":"ffffffff-0000-4000-8000-000000000006","role":"authenticated"}', false);
do $$ begin
  begin
    perform public.save_drop(jsonb_set(jsonb_set(jsonb_set(current_setting('t.drop')::jsonb, '{placement,lat}', '47.002'),
                                       '{objectId}', 'null'), '{assetId}', '"0f0f0f0f-0000-4000-8000-0000000000f1"'));
    insert into perm_test.results (test, passed, detail) values ('a turned-down upload cannot be used again', false, 'save worked');
  exception when raise_exception then
    insert into perm_test.results (test, passed, detail) values ('a turned-down upload cannot be used again', sqlerrm = 'asset_rejected', sqlerrm);
  end;
end $$;
reset role;
select set_config('request.jwt.claims', '', false);

set role authenticated;
select set_config('request.jwt.claims', '{"sub":"eeeeeeee-0000-4000-8000-000000000005","role":"authenticated"}', false);
do $$ begin
  perform public.review_drop(current_setting('t.f1'), 'reopen');
end $$;
reset role;
select set_config('request.jwt.claims', '', false);

insert into perm_test.results (test, passed, detail)
values ('putting a drop back in the queue reopens its upload',
        coalesce((select status = 'pending' from public.assets where id = '0f0f0f0f-0000-4000-8000-0000000000f1'), false),
        (select status::text from public.assets where id = '0f0f0f0f-0000-4000-8000-0000000000f1'));

-- An approved, published upload as visitors see it.
update public.assets set status = 'approved',
  public_model_path = '0d0d0d0d-0000-4000-8000-0000000000d1/model.glb',
  public_thumbnail_path = '0d0d0d0d-0000-4000-8000-0000000000d1/thumbnail.png'
where id = '0d0d0d0d-0000-4000-8000-0000000000d1';
insert into public.drops (id, owner_id, type, title, asset_id, lat, lng, time_zone, review)
values ('uptest01', 'dddddddd-0000-4000-8000-000000000004', 'object', 'Uploaded model',
        '0d0d0d0d-0000-4000-8000-0000000000d1', 47.1, -30.0, 'UTC', 'approved');

set role anon;
do $$
declare v_json jsonb;
begin
  v_json := public.public_drop('uptest01');
  insert into perm_test.results (test, passed, detail)
  values ('visitors get only the public copy of an upload',
          v_json -> 'asset' ->> 'model' = '0d0d0d0d-0000-4000-8000-0000000000d1/model.glb'
          and v_json -> 'assetFiles' is null
          and position('dddddddd-0000-4000-8000-000000000004' in v_json::text) = 0,
          v_json -> 'asset' ->> 'model');
end $$;
reset role;
select set_config('request.jwt.claims', '', false);

-- A test whose check finds no row records nothing, so make sure none went missing.
-- Update this number when adding or removing a test.
insert into perm_test.results (test, passed, detail)
select 'every test recorded a result', count(*) = 85, count(*)::text || ' of 85'
from perm_test.results;

-- ===== Clean up, then show the results ====================================
drop table if exists pg_temp.perm_test_results;
create temp table perm_test_results as select * from perm_test.results;
delete from auth.users where id in (
  'aaaaaaaa-0000-4000-8000-000000000001', 'bbbbbbbb-0000-4000-8000-000000000002',
  'cccccccc-0000-4000-8000-000000000003', 'dddddddd-0000-4000-8000-000000000004',
  'eeeeeeee-0000-4000-8000-000000000005', 'ffffffff-0000-4000-8000-000000000006');
delete from public.moderation_events
where drop_id in (current_setting('t.d1'), current_setting('t.a1'), current_setting('t.a_open'), current_setting('t.f1'));
delete from public.reports
where drop_id in (current_setting('t.a1'), current_setting('t.a_open'))
   or (drop_id is null and contact = 'owner@example.invalid');
drop schema perm_test cascade;

select n, passed, test, detail from perm_test_results order by n;
