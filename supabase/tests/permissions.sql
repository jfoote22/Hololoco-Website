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
  insert into perm_test.results (test, passed, detail) values ('a new account''s drops go live at once', v_review = 'approved', v_review);

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
declare v_id text; v_review text; v_check text;
begin
  v_id := public.save_drop(current_setting('t.drop')::jsonb);
  select review, check_state into v_review, v_check from public.drops where id = v_id;
  insert into perm_test.results (test, passed, detail)
  values ('with the automatic check off, nothing waits for it', v_review = 'approved' and v_check is null,
          v_review || ', ' || coalesce(v_check, 'no check'));

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
-- D has a strike from earlier, so D's drops wait for a person.
update public.profiles set strikes = 1 where id = 'dddddddd-0000-4000-8000-000000000004';

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
declare v_id text; v_review text; v_check text;
begin
  v_id := public.save_drop(jsonb_set(current_setting('t.drop')::jsonb, '{placement,lat}', '46.0003'));
  select review, check_state into v_review, v_check from public.drops where id = v_id;
  insert into perm_test.results (test, passed, detail)
  values ('staff drops skip limits, review and the check', v_review = 'approved' and v_check is null, v_review);
exception when others then
  insert into perm_test.results (test, passed, detail) values ('staff drops skip limits and review', false, sqlerrm);
end $$;
reset role;
select set_config('request.jwt.claims', '', false);

-- ===== The review queue ===================================================
-- D's link-only drop (t.d1) waits for a person because of D's strike.
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
  select 'staff see drops waiting for review, with the owner''s strikes',
         exists (select 1 from public.review_queue() j
                 where j ->> 'id' = current_setting('t.d1') and (j ->> 'ownerStrikes')::int = 1
                   and j ->> 'ownerStanding' = 'review'), null;

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

insert into perm_test.results (test, passed, detail)
values ('not approving a drop is a strike',
        (select strikes from public.profiles where id = 'dddddddd-0000-4000-8000-000000000004') = 2,
        (select strikes::text from public.profiles where id = 'dddddddd-0000-4000-8000-000000000004'));

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

  insert into perm_test.results (test, passed, detail)
  values ('owners see a complaint put their account under review',
          public.my_standing() ->> 'standing' = 'review', public.my_standing()::text);

  update public.drops set title = 'Changed after a complaint' where id = current_setting('t.a_over');
  insert into perm_test.results (test, passed, detail)
  values ('after a complaint, a person checks the account''s changes',
          (select review from public.drops where id = current_setting('t.a_over')) = 'pending', null);
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

-- A complaint about one of B's drops, which staff will keep.
select set_config('t.b_old', (select id from public.drops where owner_id = 'bbbbbbbb-0000-4000-8000-000000000002' order by id limit 1), false);
set role anon;
select set_config('request.headers', '{"x-forwarded-for":"10.0.0.5"}', false);
select public.file_report(current_setting('t.b_old'), 'spam');
reset role;
select set_config('request.jwt.claims', '', false);
select set_config('request.headers', '', false);
insert into perm_test.results (test, passed, detail)
values ('a complaint puts the account under review', public.account_standing('bbbbbbbb-0000-4000-8000-000000000002') = 'review',
        public.account_standing('bbbbbbbb-0000-4000-8000-000000000002'));

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
  perform public.review_drop(current_setting('t.b_old'), 'approve');

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
insert into perm_test.results (test, passed, detail)
values ('taking a drop down is a strike, and the account stays under review',
        (select strikes from public.profiles where id = 'aaaaaaaa-0000-4000-8000-000000000001') = 1 and public.account_standing('aaaaaaaa-0000-4000-8000-000000000001') = 'review',
        public.account_standing('aaaaaaaa-0000-4000-8000-000000000001'));
insert into perm_test.results (test, passed, detail)
values ('keeping a reported drop returns its account to good standing', public.account_standing('bbbbbbbb-0000-4000-8000-000000000002') = 'good',
        public.account_standing('bbbbbbbb-0000-4000-8000-000000000002'));

-- ===== Uploads ============================================================
-- F already has an approved drop, so ready-made objects would go live at once.
-- Upload rows are made here as the database owner, since the files themselves
-- can only be uploaded through Supabase Storage.

insert into auth.users (id, aud, role, email) values
  ('ffffffff-0000-4000-8000-000000000006', 'authenticated', 'authenticated', 'f@example.invalid');
update public.profiles set display_name = 'Tester', adult_confirmed_at = now(), plan = 'plus'
where id = 'ffffffff-0000-4000-8000-000000000006';
insert into public.drops (owner_id, type, title, object_id, lat, lng, time_zone, review)
values ('ffffffff-0000-4000-8000-000000000006', 'object', 'Earlier drop', 'gift', 47.0, -30.0, 'UTC', 'approved');

insert into public.assets (id, owner_id, kind, source_format, triangles, model_path, thumbnail_path)
values
  ('0f0f0f0f-0000-4000-8000-0000000000f1', 'ffffffff-0000-4000-8000-000000000006', 'model', 'fbx', 20000,
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
  begin
    insert into public.assets (id, owner_id, kind, source_format, triangles, model_path, thumbnail_path)
    values ('0e0e0e0e-0000-4000-8000-0000000000e2', 'ffffffff-0000-4000-8000-000000000006', 'model', 'glb', 20001,
            'ffffffff-0000-4000-8000-000000000006/0e0e0e0e-0000-4000-8000-0000000000e2/model.glb',
            'ffffffff-0000-4000-8000-000000000006/0e0e0e0e-0000-4000-8000-0000000000e2/thumbnail.png');
    insert into perm_test.results (test, passed, detail) values ('models have at most 20,000 triangles', false, 'insert worked');
  exception when check_violation then
    insert into perm_test.results (test, passed, detail) values ('models have at most 20,000 triangles', true, sqlerrm);
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

-- ===== Offers =============================================================
-- G is a business with no drops yet.

insert into auth.users (id, aud, role, email) values
  ('abababab-0000-4000-8000-000000000007', 'authenticated', 'authenticated', 'g@example.invalid');
update public.profiles set display_name = 'Test Bakery', adult_confirmed_at = now(), plan = 'business'
where id = 'abababab-0000-4000-8000-000000000007';
select set_config('t.offer', jsonb_set(jsonb_set(jsonb_set(current_setting('t.drop')::jsonb,
  '{type}', '"offer"'), '{placement,lat}', '48.0'),
  '{offer}', '{"savings": "Buy one, get one free", "terms": "Pastries only.", "quantity": 50, "perPerson": 1,
               "rarity": "rare", "inQuests": true}')::text, false);

set role authenticated;
select set_config('request.jwt.claims', '{"sub":"abababab-0000-4000-8000-000000000007","role":"authenticated"}', false);
do $$
declare v_id text; v_json jsonb;
begin
  begin
    perform public.save_drop(current_setting('t.offer')::jsonb - 'offer');
    insert into perm_test.results (test, passed, detail) values ('an offer has to say what people get', false, 'save worked');
  exception when raise_exception then
    insert into perm_test.results (test, passed, detail) values ('an offer has to say what people get', sqlerrm = 'offer_incomplete', sqlerrm);
  end;

  v_id := public.save_drop(current_setting('t.offer')::jsonb);
  perform set_config('t.g1', v_id, false);
  select j into v_json from public.my_drops() j where j ->> 'id' = v_id;
  insert into perm_test.results (test, passed, detail)
  values ('offers go live with their rarity and quests choice',
          v_json -> 'offer' ->> 'savings' = 'Buy one, get one free' and v_json -> 'offer' ->> 'rarity' = 'rare'
          and (v_json -> 'offer' ->> 'inQuests')::boolean and (v_json -> 'offer' ->> 'remaining')::int = 50
          and v_json ->> 'review' = 'approved' and v_json -> 'check' = 'null'::jsonb, v_json::text);

  begin
    update public.drops set check_state = 'done' where id = v_id;
    insert into perm_test.results (test, passed, detail) values ('owners cannot change a check', false, 'update worked');
  exception when insufficient_privilege then
    insert into perm_test.results (test, passed, detail) values ('owners cannot change a check', true, sqlerrm);
  end;

  begin
    update public.offers set claimed = 49 where drop_id = v_id;
    insert into perm_test.results (test, passed, detail) values ('owners cannot set how many were claimed', false, 'update worked');
  exception when insufficient_privilege then
    insert into perm_test.results (test, passed, detail) values ('owners cannot set how many were claimed', true, sqlerrm);
  end;

  begin
    update public.profiles set strikes = 0 where id = 'abababab-0000-4000-8000-000000000007';
    insert into perm_test.results (test, passed, detail) values ('people cannot clear their own strikes', false, 'update worked');
  exception when insufficient_privilege then
    insert into perm_test.results (test, passed, detail) values ('people cannot clear their own strikes', true, sqlerrm);
  end;

  begin
    perform 1 from public.drop_checks limit 1;
    insert into perm_test.results (test, passed, detail) values ('people cannot read the checks', false, 'select worked');
  exception when insufficient_privilege then
    insert into perm_test.results (test, passed, detail) values ('people cannot read the checks', true, sqlerrm);
  end;

  begin
    perform private.finish_check(1, '{"decision": "approve"}');
    insert into perm_test.results (test, passed, detail) values ('people cannot record a check', false, 'call worked');
  exception when insufficient_privilege then
    insert into perm_test.results (test, passed, detail) values ('people cannot record a check', true, sqlerrm);
  end;

  update public.offers set in_quests = false, quantity = 40, rarity = 'uncommon' where drop_id = v_id;
  insert into perm_test.results (test, passed, detail)
  values ('in good standing, changing an offer stays live',
          (select review from public.drops where id = v_id) = 'approved', null);
end $$;
reset role;
select set_config('request.jwt.claims', '', false);

-- B can't read or change G's offer.
set role authenticated;
select set_config('request.jwt.claims', '{"sub":"bbbbbbbb-0000-4000-8000-000000000002","role":"authenticated"}', false);
do $$
declare v_count int;
begin
  update public.offers set savings = 'Everything free' where drop_id = current_setting('t.g1');
  get diagnostics v_count = row_count;
  insert into perm_test.results (test, passed, detail)
  values ('people cannot read or change others'' offers',
          v_count = 0 and (select count(*) from public.offers where drop_id = current_setting('t.g1')) = 0, v_count::text);
end $$;
reset role;
select set_config('request.jwt.claims', '', false);

set role anon;
do $$
declare v_json jsonb;
begin
  v_json := public.public_drop(current_setting('t.g1'));
  insert into perm_test.results (test, passed, detail)
  values ('visitors see an offer''s public fields',
          v_json -> 'offer' ->> 'rarity' = 'uncommon' and (v_json -> 'offer' ->> 'remaining')::int = 40
          and v_json -> 'offer' -> 'claimed' is null and v_json -> 'check' is null, (v_json -> 'offer')::text);
end $$;
reset role;
select set_config('request.jwt.claims', '', false);

-- ===== The automatic check, switched on for these tests ===================
-- G has a strike, so G's changes wait for a person, and the check looks first.

select private.set_automatic_check(true);
update public.profiles set strikes = 1 where id = 'abababab-0000-4000-8000-000000000007';
insert into perm_test.results (test, passed, detail)
values ('switching the check on schedules its retry job',
        exists (select 1 from cron.job where jobname = 'retry-drop-checks'), null);

set role authenticated;
select set_config('request.jwt.claims', '{"sub":"abababab-0000-4000-8000-000000000007","role":"authenticated"}', false);
do $$ begin
  update public.offers set savings = 'Buy one pastry, get one free' where drop_id = current_setting('t.g1');
  insert into perm_test.results (test, passed, detail)
  values ('with the check on, what would wait for a person goes to it first',
          (select review = 'pending' and check_state = 'queued' from public.drops where id = current_setting('t.g1')), null);
end $$;
reset role;
select set_config('request.jwt.claims', '', false);

do $$
declare v_ctx jsonb; v_outcome text;
begin
  v_ctx := private.claim_check(current_setting('t.g1'));
  insert into perm_test.results (test, passed, detail)
  values ('the check sees the offer and its owner''s record',
          v_ctx -> 'drop' -> 'offer' ->> 'savings' = 'Buy one pastry, get one free'
          and (v_ctx -> 'owner' ->> 'approvedDrops')::int = 0, left(v_ctx::text, 200));
  insert into perm_test.results (test, passed, detail)
  values ('only one call can claim a check', private.claim_check(current_setting('t.g1')) is null, null);
  v_outcome := private.finish_check((v_ctx ->> 'runId')::bigint, '{"decision": "approve", "suggestedRarity": "common",
    "rarityReason": "A free pastry is worth a few dollars.", "placementTip": "Put it by the door.",
    "reason": "Fine.", "concerns": [], "ownerNote": "Looks good."}');
  insert into perm_test.results (test, passed, detail)
  values ('the check approves an offer',
          v_outcome = 'approve' and (select review from public.drops where id = current_setting('t.g1')) = 'approved', v_outcome);
  insert into perm_test.results (test, passed, detail)
  values ('automatic approvals are logged',
          exists (select 1 from public.moderation_events
                  where drop_id = current_setting('t.g1') and action = 'approve' and automatic and actor_id is null), null);
end $$;

set role authenticated;
select set_config('request.jwt.claims', '{"sub":"abababab-0000-4000-8000-000000000007","role":"authenticated"}', false);
do $$
declare v_json jsonb;
begin
  select j into v_json from public.my_drops() j where j ->> 'id' = current_setting('t.g1');
  insert into perm_test.results (test, passed, detail)
  values ('owners see the check''s suggestions, not its notes for staff',
          v_json -> 'check' ->> 'suggestedRarity' = 'common' and v_json -> 'check' ->> 'placementTip' = 'Put it by the door.'
          and v_json -> 'check' -> 'reason' is null and v_json -> 'check' -> 'concerns' is null, (v_json -> 'check')::text);

  update public.offers set rarity = 'rare' where drop_id = current_setting('t.g1');
end $$;
reset role;
select set_config('request.jwt.claims', '', false);

-- A person turns it down while the check is running; the check's late answer changes nothing.
select set_config('t.g1_run', (private.claim_check(current_setting('t.g1')) ->> 'runId'), false);
set role authenticated;
select set_config('request.jwt.claims', '{"sub":"eeeeeeee-0000-4000-8000-000000000005","role":"authenticated"}', false);
do $$ begin
  perform public.review_drop(current_setting('t.g1'), 'reject', 'It''s spam.');
end $$;
reset role;
select set_config('request.jwt.claims', '', false);
select set_config('t.g1_late', private.finish_check(current_setting('t.g1_run')::bigint, '{"decision": "approve"}'), false);
insert into perm_test.results (test, passed, detail)
values ('a late check can''t undo a person''s decision',
        current_setting('t.g1_late') = 'ignored'
        and (select review from public.drops where id = current_setting('t.g1')) = 'rejected', current_setting('t.g1_late'));

set role authenticated;
select set_config('request.jwt.claims', '{"sub":"abababab-0000-4000-8000-000000000007","role":"authenticated"}', false);
do $$ begin
  perform public.save_drop(jsonb_set(jsonb_set(current_setting('t.offer')::jsonb, '{id}', to_jsonb(current_setting('t.g1'))),
                                     '{title}', '"Fixed offer"'));
  perform set_config('t.g2', public.save_drop(jsonb_set(jsonb_set(current_setting('t.drop')::jsonb,
    '{type}', '"message"'), '{placement,lat}', '48.001')), false);
  perform set_config('t.g3', public.save_drop(jsonb_set(jsonb_set(current_setting('t.drop')::jsonb,
    '{type}', '"message"'), '{placement,lat}', '48.002')), false);
  perform set_config('t.g4', public.save_drop(jsonb_set(jsonb_set(current_setting('t.drop')::jsonb,
    '{type}', '"message"'), '{placement,lat}', '48.003')), false);
end $$;
reset role;
select set_config('request.jwt.claims', '', false);

do $$
declare v_ctx jsonb; v_outcome text;
begin
  v_ctx := private.claim_check(current_setting('t.g1'));
  v_outcome := private.finish_check((v_ctx ->> 'runId')::bigint, '{"decision": "approve"}');
  insert into perm_test.results (test, passed, detail)
  values ('the check can''t approve what a person turned down',
          (v_ctx ->> 'turnedDownByAPersonBefore')::boolean and v_outcome = 'hold'
          and (select review from public.drops where id = current_setting('t.g1')) = 'pending', v_outcome);

  v_ctx := private.claim_check(current_setting('t.g2'));
  perform private.fail_check((v_ctx ->> 'runId')::bigint, 'Test failure');
  insert into perm_test.results (test, passed, detail)
  values ('a failed check is tried again', (select check_state from public.drops where id = current_setting('t.g2')) = 'retry', null);

  perform set_config('hololoco.system', 'on', true);
  update public.drops set check_at = now() - interval '2 minutes' where id = current_setting('t.g2');
  perform set_config('hololoco.system', '', true);
  perform private.retry_checks();
  insert into perm_test.results (test, passed, detail)
  values ('the retry job queues it again', (select check_state from public.drops where id = current_setting('t.g2')) = 'queued', null);

  v_ctx := private.claim_check(current_setting('t.g2'));
  perform private.fail_check((v_ctx ->> 'runId')::bigint, 'not_configured', true);

  -- Nothing ever claims G's fourth drop, as if the Edge Function couldn't be reached.
  for i in 1..4 loop
    perform set_config('hololoco.system', 'on', true);
    update public.drops set check_at = now() - interval '3 minutes' where id = current_setting('t.g4');
    perform set_config('hololoco.system', '', true);
    perform private.retry_checks();
  end loop;
  insert into perm_test.results (test, passed, detail)
  values ('a check nobody answers ends with a person',
          (select check_state from public.drops where id = current_setting('t.g4')) = 'failed',
          (select check_state from public.drops where id = current_setting('t.g4')));

  insert into public.drop_checks (drop_id, owner_id, status)
  select 'x', 'abababab-0000-4000-8000-000000000007', 'done' from generate_series(1, 40);
  v_ctx := private.claim_check(current_setting('t.g3'));
  insert into perm_test.results (test, passed, detail)
  values ('forty checks a day per account at most',
          v_ctx is null and (select check_state from public.drops where id = current_setting('t.g3')) = 'failed', null);
end $$;

set role authenticated;
select set_config('request.jwt.claims', '{"sub":"eeeeeeee-0000-4000-8000-000000000005","role":"authenticated"}', false);
do $$ begin
  insert into perm_test.results (test, passed, detail)
  select 'a check that can''t run hands the drop to a person',
         exists (select 1 from public.review_queue() j
                 where j ->> 'id' = current_setting('t.g2') and j -> 'check' ->> 'error' = 'not_configured'), null;
end $$;
reset role;
select set_config('request.jwt.claims', '', false);

select private.set_automatic_check(false);
set role authenticated;
select set_config('request.jwt.claims', '{"sub":"abababab-0000-4000-8000-000000000007","role":"authenticated"}', false);
do $$
declare v_id text;
begin
  v_id := public.save_drop(jsonb_set(jsonb_set(current_setting('t.drop')::jsonb,
    '{type}', '"message"'), '{placement,lat}', '48.004'));
  perform set_config('t.g5', v_id, false);
  insert into perm_test.results (test, passed, detail)
  values ('with the check off, it waits for a person instead',
          (select review = 'pending' and check_state is null from public.drops where id = v_id), null);
end $$;
reset role;
select set_config('request.jwt.claims', '', false);
insert into perm_test.results (test, passed, detail)
values ('switching the check off stops its retry job',
        not exists (select 1 from cron.job where jobname = 'retry-drop-checks'), null);

-- ===== Three strikes ======================================================
-- H has a live drop and two strikes from earlier.

insert into auth.users (id, aud, role, email) values
  ('cdcdcdcd-0000-4000-8000-000000000008', 'authenticated', 'authenticated', 'h@example.invalid');
update public.profiles set display_name = 'Test Shop', adult_confirmed_at = now() where id = 'cdcdcdcd-0000-4000-8000-000000000008';

set role authenticated;
select set_config('request.jwt.claims', '{"sub":"cdcdcdcd-0000-4000-8000-000000000008","role":"authenticated"}', false);
do $$ begin
  perform set_config('t.h1', public.save_drop(jsonb_set(current_setting('t.drop')::jsonb, '{placement,lat}', '49.0')), false);
end $$;
reset role;
select set_config('request.jwt.claims', '', false);
update public.profiles set strikes = 2 where id = 'cdcdcdcd-0000-4000-8000-000000000008';

set role authenticated;
select set_config('request.jwt.claims', '{"sub":"cdcdcdcd-0000-4000-8000-000000000008","role":"authenticated"}', false);
do $$
declare v_id text;
begin
  v_id := public.save_drop(jsonb_set(current_setting('t.drop')::jsonb, '{placement,lat}', '49.001'));
  perform set_config('t.h2', v_id, false);
  insert into perm_test.results (test, passed, detail)
  values ('an account with a strike waits for a person', (select review from public.drops where id = v_id) = 'pending', null);
end $$;
reset role;
select set_config('request.jwt.claims', '', false);

set role anon;
do $$ begin
  insert into perm_test.results (test, passed, detail)
  values ('drops waiting for a person are not public', public.public_drop(current_setting('t.h2')) is null, null);
end $$;
reset role;
select set_config('request.jwt.claims', '', false);

set role authenticated;
select set_config('request.jwt.claims', '{"sub":"eeeeeeee-0000-4000-8000-000000000005","role":"authenticated"}', false);
do $$ begin
  perform public.review_drop(current_setting('t.h2'), 'reject', 'It''s spam.');
end $$;
reset role;
select set_config('request.jwt.claims', '', false);

insert into perm_test.results (test, passed, detail)
values ('three strikes suspend the account', public.account_standing('cdcdcdcd-0000-4000-8000-000000000008') = 'suspended', public.account_standing('cdcdcdcd-0000-4000-8000-000000000008'));

set role anon;
do $$ begin
  insert into perm_test.results (test, passed, detail)
  values ('a suspended account''s drops leave the map',
          public.public_drop(current_setting('t.h1')) is null
          and not exists (select 1 from public.public_drops_in_bounds(-30.01, 48.99, -29.99, 49.01) j
                          where j ->> 'id' = current_setting('t.h1')), null);
end $$;
reset role;
select set_config('request.jwt.claims', '', false);

set role authenticated;
select set_config('request.jwt.claims', '{"sub":"cdcdcdcd-0000-4000-8000-000000000008","role":"authenticated"}', false);
do $$ begin
  insert into perm_test.results (test, passed, detail)
  values ('owners see their account is suspended', public.my_standing() ->> 'standing' = 'suspended', public.my_standing()::text);
  begin
    perform public.save_drop(jsonb_set(current_setting('t.drop')::jsonb, '{placement,lat}', '49.002'));
    insert into perm_test.results (test, passed, detail) values ('suspended accounts cannot add drops', false, 'save worked');
  exception when raise_exception then
    insert into perm_test.results (test, passed, detail) values ('suspended accounts cannot add drops', sqlerrm = 'account_suspended', sqlerrm);
  end;
  begin
    update public.drops set paused = true where id = current_setting('t.h1');
    insert into perm_test.results (test, passed, detail) values ('suspended accounts cannot change drops', false, 'update worked');
  exception when raise_exception then
    insert into perm_test.results (test, passed, detail) values ('suspended accounts cannot change drops', sqlerrm = 'account_suspended', sqlerrm);
  end;
end $$;
reset role;
select set_config('request.jwt.claims', '', false);

set role authenticated;
select set_config('request.jwt.claims', '{"sub":"eeeeeeee-0000-4000-8000-000000000005","role":"authenticated"}', false);
do $$ begin
  perform public.review_drop(current_setting('t.h2'), 'reopen');
end $$;
reset role;
select set_config('request.jwt.claims', '', false);

insert into perm_test.results (test, passed, detail)
values ('undoing a decision takes its strike back',
        (select strikes from public.profiles where id = 'cdcdcdcd-0000-4000-8000-000000000008') = 2 and public.account_standing('cdcdcdcd-0000-4000-8000-000000000008') = 'review'
        and public.public_drop(current_setting('t.h1')) is not null, null);

-- ===== Quests =============================================================
-- Five businesses with groups of opted-in offers, each group a degree of
-- latitude from the next. Offers are made here as the database owner.

insert into auth.users (id, aud, role, email) values
  ('a1a1a1a1-0000-4000-8000-000000000011', 'authenticated', 'authenticated', 'q1@example.invalid'),
  ('a2a2a2a2-0000-4000-8000-000000000012', 'authenticated', 'authenticated', 'q2@example.invalid'),
  ('a3a3a3a3-0000-4000-8000-000000000013', 'authenticated', 'authenticated', 'q3@example.invalid'),
  ('a4a4a4a4-0000-4000-8000-000000000014', 'authenticated', 'authenticated', 'q4@example.invalid'),
  ('a5a5a5a5-0000-4000-8000-000000000015', 'authenticated', 'authenticated', 'q5@example.invalid');
update public.profiles set display_name = 'Quest Shop ' || right(id::text, 1), adult_confirmed_at = now()
where id in ('a1a1a1a1-0000-4000-8000-000000000011', 'a2a2a2a2-0000-4000-8000-000000000012',
             'a3a3a3a3-0000-4000-8000-000000000013', 'a4a4a4a4-0000-4000-8000-000000000014',
             'a5a5a5a5-0000-4000-8000-000000000015');

create function perm_test.offer(p_owner uuid, p_lat double precision, p_rarity text)
returns text
language plpgsql
as $$
declare v_id text;
begin
  insert into public.drops (owner_id, type, title, object_id, lat, lng, time_zone, review)
  values (p_owner, 'offer', 'Quest test', 'gift', p_lat, -30.0, 'UTC', 'approved')
  returning id into v_id;
  insert into public.offers (drop_id, savings, quantity, rarity, in_quests)
  values (v_id, 'A test deal', 10, p_rarity, true);
  return v_id;
end;
$$;

-- A: four stages within a short walk, and a common offer far away.
select set_config('t.qa1', perm_test.offer('a1a1a1a1-0000-4000-8000-000000000011', 50.000, 'common'), false);
select set_config('t.qa2', perm_test.offer('a2a2a2a2-0000-4000-8000-000000000012', 50.003, 'uncommon'), false);
select set_config('t.qa3', perm_test.offer('a3a3a3a3-0000-4000-8000-000000000013', 50.006, 'uncommon'), false);
select set_config('t.qa4', perm_test.offer('a4a4a4a4-0000-4000-8000-000000000014', 50.009, 'rare'), false);
select set_config('t.qa5', perm_test.offer('a5a5a5a5-0000-4000-8000-000000000015', 51.000, 'common'), false);
-- B: the common and uncommon offers are never open at the same time.
select set_config('t.qb1', perm_test.offer('a1a1a1a1-0000-4000-8000-000000000011', 52.000, 'common'), false);
select set_config('t.qb2', perm_test.offer('a2a2a2a2-0000-4000-8000-000000000012', 52.003, 'uncommon'), false);
select set_config('t.qb3', perm_test.offer('a3a3a3a3-0000-4000-8000-000000000013', 52.006, 'rare'), false);
update public.drops set timing = 'weekly' where id in (current_setting('t.qb1'), current_setting('t.qb2'));
insert into public.schedule_blocks (drop_id, days, start_time, end_time) values
  (current_setting('t.qb1'), '{1}', '09:00', '12:00'),
  (current_setting('t.qb2'), '{1}', '13:00', '17:00');
-- C: one uncommon offer, so three stages.
select set_config('t.qc1', perm_test.offer('a1a1a1a1-0000-4000-8000-000000000011', 54.000, 'common'), false);
select set_config('t.qc2', perm_test.offer('a2a2a2a2-0000-4000-8000-000000000012', 54.003, 'uncommon'), false);
select set_config('t.qc3', perm_test.offer('a3a3a3a3-0000-4000-8000-000000000013', 54.006, 'rare'), false);
-- D: about 3 km between stages, as in the countryside.
select set_config('t.qd1', perm_test.offer('a1a1a1a1-0000-4000-8000-000000000011', 56.00, 'common'), false);
select set_config('t.qd2', perm_test.offer('a2a2a2a2-0000-4000-8000-000000000012', 56.03, 'uncommon'), false);
select set_config('t.qd3', perm_test.offer('a3a3a3a3-0000-4000-8000-000000000013', 56.06, 'rare'), false);
-- E: the common and uncommon offers are from the same business.
select set_config('t.qe1', perm_test.offer('a1a1a1a1-0000-4000-8000-000000000011', 58.000, 'common'), false);
select set_config('t.qe2', perm_test.offer('a1a1a1a1-0000-4000-8000-000000000011', 58.003, 'uncommon'), false);
select set_config('t.qe3', perm_test.offer('a2a2a2a2-0000-4000-8000-000000000012', 58.006, 'rare'), false);

select private.refresh_quests();

-- The active quest an offer is in, or null.
create function perm_test.quest_of(p_drop text)
returns text
language sql
as $$
  select q.id from public.quest_stages s join public.quests q on q.id = s.quest_id
  where s.drop_id = p_drop and q.status = 'active' limit 1;
$$;

select set_config('t.qa_quest', coalesce(perm_test.quest_of(current_setting('t.qa1')), ''), false);
select set_config('t.qc_quest', coalesce(perm_test.quest_of(current_setting('t.qc1')), ''), false);
select set_config('t.qd_quest', coalesce(perm_test.quest_of(current_setting('t.qd1')), ''), false);

insert into perm_test.results (test, passed, detail)
select 'the builder links common, uncommon and rare offers in that order',
       coalesce((select array_agg(s.drop_id || ':' || s.rarity order by s.position)
                 from public.quest_stages s where s.quest_id = current_setting('t.qa_quest')), '{}')
         = array[current_setting('t.qa1') || ':common', current_setting('t.qa2') || ':uncommon',
                 current_setting('t.qa3') || ':uncommon', current_setting('t.qa4') || ':rare']
       and (select stage_count = 4 and max_leg_m = 1600 from public.quests where id = current_setting('t.qa_quest')),
       current_setting('t.qa_quest');
insert into perm_test.results (test, passed, detail)
select 'a quest can have three stages',
       coalesce((select array_agg(s.drop_id order by s.position)
                 from public.quest_stages s where s.quest_id = current_setting('t.qc_quest')), '{}')
         = array[current_setting('t.qc1'), current_setting('t.qc2'), current_setting('t.qc3')], null;
insert into perm_test.results (test, passed, detail)
select 'stages stretch farther apart where businesses are spread out',
       coalesce((select max_leg_m = 5000 and stage_count = 3 from public.quests where id = current_setting('t.qd_quest')), false),
       current_setting('t.qd_quest');
insert into perm_test.results (test, passed, detail)
select 'offers too far away aren''t linked', perm_test.quest_of(current_setting('t.qa5')) is null, null;
insert into perm_test.results (test, passed, detail)
select 'stages have to be open at the same time',
       perm_test.quest_of(current_setting('t.qb1')) is null and perm_test.quest_of(current_setting('t.qb2')) is null
       and perm_test.quest_of(current_setting('t.qb3')) is null, null;
insert into perm_test.results (test, passed, detail)
select 'each stage is a different business',
       perm_test.quest_of(current_setting('t.qe1')) is null and perm_test.quest_of(current_setting('t.qe3')) is null, null;
insert into perm_test.results (test, passed, detail)
select 'an offer is in one quest at a time', (private.refresh_quests() ->> 'built')::int = 0
       and perm_test.quest_of(current_setting('t.qa1')) = current_setting('t.qa_quest'), null;

set role anon;
do $$
declare v_json jsonb;
begin
  select j into v_json from public.public_quests_in_bounds(-30.01, 49.99, -29.99, 50.01) j
  where j ->> 'id' = current_setting('t.qa_quest');
  insert into perm_test.results (test, passed, detail)
  values ('visitors can read quests and their stages',
          jsonb_array_length(v_json -> 'stages') = 4
          and v_json -> 'stages' -> 0 -> 'drop' -> 'offer' ->> 'rarity' = 'common'
          and v_json ->> 'openHours' = repeat('1', 168)
          and public.public_quest(current_setting('t.qa_quest')) is not null, left(v_json::text, 200));

  begin
    perform 1 from public.quests limit 1;
    insert into perm_test.results (test, passed, detail) values ('visitors cannot read the quests table', false, 'select worked');
  exception when insufficient_privilege then
    insert into perm_test.results (test, passed, detail) values ('visitors cannot read the quests table', true, sqlerrm);
  end;
end $$;
reset role;
select set_config('request.jwt.claims', '', false);

set role authenticated;
select set_config('request.jwt.claims', '{"sub":"a2a2a2a2-0000-4000-8000-000000000012","role":"authenticated"}', false);
do $$ begin
  insert into perm_test.results (test, passed, detail)
  select 'businesses see their offer''s quest',
         (j -> 'quest' ->> 'position')::int = 2 and (j -> 'quest' ->> 'stageCount')::int = 4
         and j -> 'quest' ->> 'id' = current_setting('t.qa_quest'), (j -> 'quest')::text
  from public.my_drops() j where j ->> 'id' = current_setting('t.qa2');

  begin
    insert into public.quest_stages (quest_id, position, drop_id, rarity)
    values (current_setting('t.qa_quest'), 4, current_setting('t.qa2'), 'rare');
    insert into perm_test.results (test, passed, detail) values ('businesses cannot change quests', false, 'insert worked');
  exception when insufficient_privilege then
    insert into perm_test.results (test, passed, detail) values ('businesses cannot change quests', true, sqlerrm);
  end;

  begin
    perform public.rebuild_quests();
    insert into perm_test.results (test, passed, detail) values ('only staff can build quests', false, 'rebuild worked');
  exception when raise_exception then
    insert into perm_test.results (test, passed, detail) values ('only staff can build quests', sqlerrm = 'not_staff', sqlerrm);
  end;
end $$;
reset role;
select set_config('request.jwt.claims', '', false);

set role authenticated;
select set_config('request.jwt.claims', '{"sub":"eeeeeeee-0000-4000-8000-000000000005","role":"authenticated"}', false);
do $$ begin
  insert into perm_test.results (test, passed, detail)
  select 'staff see every quest',
         exists (select 1 from public.staff_quests() j where j ->> 'id' = current_setting('t.qa_quest')), null;
  -- Taking a stage down hides it from the quest at once, before the next refresh.
  perform public.review_drop(current_setting('t.qc2'), 'reject', 'It''s spam.');
end $$;
reset role;
select set_config('request.jwt.claims', '', false);

set role anon;
do $$ begin
  insert into perm_test.results (test, passed, detail)
  values ('a stage taken down leaves the public quest at once',
          public.public_quest(current_setting('t.qc_quest')) -> 'stages' -> 1 -> 'drop' = 'null'::jsonb, null);
end $$;
reset role;
select set_config('request.jwt.claims', '', false);

-- The rare stage of A is paused, and D's rare offer sells out.
set role authenticated;
select set_config('request.jwt.claims', '{"sub":"a4a4a4a4-0000-4000-8000-000000000014","role":"authenticated"}', false);
do $$ begin
  update public.drops set paused = true where id = current_setting('t.qa4');
end $$;
reset role;
select set_config('request.jwt.claims', '', false);
update public.offers set claimed = 10 where drop_id = current_setting('t.qd3');
select private.refresh_quests();

insert into perm_test.results (test, passed, detail)
select 'a paused stage retires its quest',
       status = 'retired' and retired_reason = 'Stage 4 is paused.', status || ': ' || coalesce(retired_reason, '')
from public.quests where id = current_setting('t.qa_quest');
insert into perm_test.results (test, passed, detail)
select 'a sold-out stage retires its quest',
       status = 'retired' and retired_reason = 'Stage 3 is sold out.', status || ': ' || coalesce(retired_reason, '')
from public.quests where id = current_setting('t.qd_quest');

set role authenticated;
select set_config('request.jwt.claims', '{"sub":"a4a4a4a4-0000-4000-8000-000000000014","role":"authenticated"}', false);
do $$ begin
  update public.drops set paused = false where id = current_setting('t.qa4');
end $$;
reset role;
select set_config('request.jwt.claims', '', false);
select private.refresh_quests();

insert into perm_test.results (test, passed, detail)
select 'a retired quest''s offers can join a new one',
       perm_test.quest_of(current_setting('t.qa1')) is not null
       and perm_test.quest_of(current_setting('t.qa1')) <> current_setting('t.qa_quest')
       and perm_test.quest_of(current_setting('t.qa4')) = perm_test.quest_of(current_setting('t.qa1')), null;

-- Test quests go before their businesses do.
delete from public.quests q
where exists (select 1 from public.quest_stages s join public.drops d on d.id = s.drop_id
              where s.quest_id = q.id
                and d.owner_id in ('a1a1a1a1-0000-4000-8000-000000000011', 'a2a2a2a2-0000-4000-8000-000000000012',
                                   'a3a3a3a3-0000-4000-8000-000000000013', 'a4a4a4a4-0000-4000-8000-000000000014',
                                   'a5a5a5a5-0000-4000-8000-000000000015'));

-- ===== The automatic photo check ==========================================
-- J posts photos; K has a strike. Upload rows are made as the database owner,
-- as above, and "copying the files" is a row in storage.objects.

insert into auth.users (id, aud, role, email) values
  ('b1b1b1b1-0000-4000-8000-000000000021', 'authenticated', 'authenticated', 'j@example.invalid'),
  ('b2b2b2b2-0000-4000-8000-000000000022', 'authenticated', 'authenticated', 'k@example.invalid');
update public.profiles set display_name = 'Photo Tester', adult_confirmed_at = now()
where id in ('b1b1b1b1-0000-4000-8000-000000000021', 'b2b2b2b2-0000-4000-8000-000000000022');
update public.profiles set strikes = 1 where id = 'b2b2b2b2-0000-4000-8000-000000000022';

insert into public.assets (id, owner_id, kind, source_format, model_path, thumbnail_path, photo_path)
select v.id::uuid, v.owner::uuid, v.kind, case v.kind when 'photo' then 'jpeg' else 'glb' end,
       v.owner || '/' || v.id || '/model.glb', v.owner || '/' || v.id || '/thumbnail.png',
       case v.kind when 'photo' then v.owner || '/' || v.id || '/photo.jpg' end
from (values
  ('c1c1c1c1-0000-4000-8000-0000000000c1', 'b1b1b1b1-0000-4000-8000-000000000021', 'photo'),
  ('c2c2c2c2-0000-4000-8000-0000000000c2', 'b1b1b1b1-0000-4000-8000-000000000021', 'photo'),
  ('c3c3c3c3-0000-4000-8000-0000000000c3', 'b1b1b1b1-0000-4000-8000-000000000021', 'photo'),
  ('c4c4c4c4-0000-4000-8000-0000000000c4', 'b2b2b2b2-0000-4000-8000-000000000022', 'photo'),
  ('c5c5c5c5-0000-4000-8000-0000000000c5', 'b1b1b1b1-0000-4000-8000-000000000021', 'model'),
  ('c6c6c6c6-0000-4000-8000-0000000000c6', 'b1b1b1b1-0000-4000-8000-000000000021', 'photo')
) v(id, owner, kind);

insert into perm_test.results (test, passed, detail)
select 'every new photo waits for the automatic check, and models don''t',
       (select scan_state = 'queued' from public.assets where id = 'c1c1c1c1-0000-4000-8000-0000000000c1')
       and (select scan_state is null from public.assets where id = 'c5c5c5c5-0000-4000-8000-0000000000c5'), null;

set role authenticated;
select set_config('request.jwt.claims', '{"sub":"b1b1b1b1-0000-4000-8000-000000000021","role":"authenticated"}', false);
do $$
declare v_json jsonb;
begin
  begin
    update public.assets set scan_state = 'done', status = 'approved' where id = 'c1c1c1c1-0000-4000-8000-0000000000c1';
    insert into perm_test.results (test, passed, detail) values ('people cannot mark their own photo as checked', false, 'update worked');
  exception when insufficient_privilege then
    insert into perm_test.results (test, passed, detail) values ('people cannot mark their own photo as checked', true, sqlerrm);
  end;

  perform set_config('t.j1', public.save_drop(jsonb_set(jsonb_set(jsonb_set(current_setting('t.drop')::jsonb,
    '{placement,lat}', '60.0'), '{objectId}', 'null'), '{assetId}', '"c1c1c1c1-0000-4000-8000-0000000000c1"')), false);
  perform set_config('t.j2', public.save_drop(jsonb_set(jsonb_set(jsonb_set(current_setting('t.drop')::jsonb,
    '{placement,lat}', '60.001'), '{objectId}', 'null'), '{assetId}', '"c2c2c2c2-0000-4000-8000-0000000000c2"')), false);
  perform set_config('t.j3', public.save_drop(jsonb_set(jsonb_set(jsonb_set(current_setting('t.drop')::jsonb,
    '{placement,lat}', '60.002'), '{objectId}', 'null'), '{assetId}', '"c3c3c3c3-0000-4000-8000-0000000000c3"')), false);

  select j into v_json from public.my_drops() j where j ->> 'id' = current_setting('t.j1');
  insert into perm_test.results (test, passed, detail)
  values ('a drop with a photo waits for its check, and its owner can see that',
          v_json ->> 'review' = 'pending' and v_json ->> 'photoCheck' = 'queued', v_json ->> 'photoCheck');
end $$;
reset role;
select set_config('request.jwt.claims', '', false);

set role authenticated;
select set_config('request.jwt.claims', '{"sub":"b2b2b2b2-0000-4000-8000-000000000022","role":"authenticated"}', false);
do $$ begin
  perform set_config('t.j4', public.save_drop(jsonb_set(jsonb_set(jsonb_set(current_setting('t.drop')::jsonb,
    '{placement,lat}', '60.003'), '{objectId}', 'null'), '{assetId}', '"c4c4c4c4-0000-4000-8000-0000000000c4"')), false);
end $$;
reset role;
select set_config('request.jwt.claims', '', false);

do $$
declare v_ctx jsonb; v_outcome text;
begin
  v_ctx := private.claim_photo_scan('c1c1c1c1-0000-4000-8000-0000000000c1');
  insert into perm_test.results (test, passed, detail)
  values ('only one call can claim a photo check',
          v_ctx ->> 'photo' = 'b1b1b1b1-0000-4000-8000-000000000021/c1c1c1c1-0000-4000-8000-0000000000c1/photo.jpg'
          and private.claim_photo_scan('c1c1c1c1-0000-4000-8000-0000000000c1') is null, v_ctx::text);

  -- Clean, but its files were never copied to the public bucket.
  v_outcome := private.finish_photo_scan('c1c1c1c1-0000-4000-8000-0000000000c1', '{"flags": []}', true);
  insert into perm_test.results (test, passed, detail)
  values ('a photo is only published once its files are copied',
          v_outcome = 'failed' and (select status = 'pending' from public.assets where id = 'c1c1c1c1-0000-4000-8000-0000000000c1'),
          v_outcome);

  -- Clean, with its files copied.
  perform private.claim_photo_scan('c2c2c2c2-0000-4000-8000-0000000000c2');
  insert into storage.objects (bucket_id, name) values
    ('drop-assets', 'c2c2c2c2-0000-4000-8000-0000000000c2/model.glb'),
    ('drop-assets', 'c2c2c2c2-0000-4000-8000-0000000000c2/thumbnail.png'),
    ('drop-assets', 'c2c2c2c2-0000-4000-8000-0000000000c2/photo.jpg');
  v_outcome := private.finish_photo_scan('c2c2c2c2-0000-4000-8000-0000000000c2', '{"flags": []}', true);
  insert into perm_test.results (test, passed, detail)
  values ('a clean photo goes live by itself',
          v_outcome = 'published'
          and (select review from public.drops where id = current_setting('t.j2')) = 'approved'
          and (select status = 'approved' and public_photo_path = 'c2c2c2c2-0000-4000-8000-0000000000c2/photo.jpg'
               from public.assets where id = 'c2c2c2c2-0000-4000-8000-0000000000c2'), v_outcome);
  insert into perm_test.results (test, passed, detail)
  values ('automatic photo approvals are logged',
          exists (select 1 from public.moderation_events
                  where drop_id = current_setting('t.j2') and action = 'approve' and automatic
                    and reason = 'Automatic photo check'), null);

  -- Flagged.
  perform private.claim_photo_scan('c3c3c3c3-0000-4000-8000-0000000000c3');
  v_outcome := private.finish_photo_scan('c3c3c3c3-0000-4000-8000-0000000000c3', '{"flags": ["Adult content: likely"]}', false);
  insert into perm_test.results (test, passed, detail)
  values ('a flagged photo isn''t published',
          v_outcome = 'held' and (select status = 'pending' and public_photo_path is null
                                  from public.assets where id = 'c3c3c3c3-0000-4000-8000-0000000000c3')
          and (select review from public.drops where id = current_setting('t.j3')) = 'pending', v_outcome);

  -- Clean, from an account with a strike.
  perform private.claim_photo_scan('c4c4c4c4-0000-4000-8000-0000000000c4');
  insert into storage.objects (bucket_id, name) values
    ('drop-assets', 'c4c4c4c4-0000-4000-8000-0000000000c4/model.glb'),
    ('drop-assets', 'c4c4c4c4-0000-4000-8000-0000000000c4/thumbnail.png'),
    ('drop-assets', 'c4c4c4c4-0000-4000-8000-0000000000c4/photo.jpg');
  v_outcome := private.finish_photo_scan('c4c4c4c4-0000-4000-8000-0000000000c4', '{"flags": []}', true);
  insert into perm_test.results (test, passed, detail)
  values ('a clean photo from an account under review still waits for a person',
          v_outcome = 'published' and (select review from public.drops where id = current_setting('t.j4')) = 'pending', v_outcome);

  -- The check can't run.
  perform private.claim_photo_scan('c6c6c6c6-0000-4000-8000-0000000000c6');
  perform private.fail_photo_scan('c6c6c6c6-0000-4000-8000-0000000000c6', 'not_configured');
  insert into perm_test.results (test, passed, detail)
  values ('a photo check that can''t run is marked for a person',
          (select scan_state = 'failed' and scan ->> 'error' = 'not_configured'
           from public.assets where id = 'c6c6c6c6-0000-4000-8000-0000000000c6'), null);
end $$;

set role anon;
do $$ begin
  insert into perm_test.results (test, passed, detail)
  values ('visitors see a photo that passed the check',
          public.public_drop(current_setting('t.j2')) -> 'asset' ->> 'photo' = 'c2c2c2c2-0000-4000-8000-0000000000c2/photo.jpg', null);
end $$;
reset role;
select set_config('request.jwt.claims', '', false);

set role authenticated;
select set_config('request.jwt.claims', '{"sub":"eeeeeeee-0000-4000-8000-000000000005","role":"authenticated"}', false);
do $$ begin
  insert into perm_test.results (test, passed, detail)
  select 'staff see flagged photos in the queue, with what was flagged',
         exists (select 1 from public.review_queue() j
                 where j ->> 'id' = current_setting('t.j3')
                   and j -> 'photoCheck' -> 'result' -> 'flags' ->> 0 = 'Adult content: likely')
         and exists (select 1 from public.review_queue() j
                     where j ->> 'id' = current_setting('t.j1') and j -> 'photoCheck' ->> 'state' = 'failed'), null;
end $$;
reset role;
select set_config('request.jwt.claims', '', false);

delete from storage.objects
where bucket_id = 'drop-assets'
  and name in ('c2c2c2c2-0000-4000-8000-0000000000c2/model.glb', 'c2c2c2c2-0000-4000-8000-0000000000c2/thumbnail.png',
               'c2c2c2c2-0000-4000-8000-0000000000c2/photo.jpg', 'c4c4c4c4-0000-4000-8000-0000000000c4/model.glb',
               'c4c4c4c4-0000-4000-8000-0000000000c4/thumbnail.png', 'c4c4c4c4-0000-4000-8000-0000000000c4/photo.jpg');

-- ===== Plans ==============================================================
-- P1 starts on Free and becomes a business. P2 and P3 are players. P4 runs
-- events; P5 is a third business for quests.

insert into auth.users (id, aud, role, email) values
  ('f1f1f1f1-0000-4000-8000-000000000031', 'authenticated', 'authenticated', 'p1@example.invalid'),
  ('f2f2f2f2-0000-4000-8000-000000000032', 'authenticated', 'authenticated', 'p2@example.invalid'),
  ('f3f3f3f3-0000-4000-8000-000000000033', 'authenticated', 'authenticated', 'p3@example.invalid'),
  ('f4f4f4f4-0000-4000-8000-000000000034', 'authenticated', 'authenticated', 'p4@example.invalid'),
  ('f5f5f5f5-0000-4000-8000-000000000035', 'authenticated', 'authenticated', 'p5@example.invalid');
update public.profiles set display_name = 'Play Tester ' || right(id::text, 1), adult_confirmed_at = now()
where id in ('f1f1f1f1-0000-4000-8000-000000000031', 'f2f2f2f2-0000-4000-8000-000000000032',
             'f3f3f3f3-0000-4000-8000-000000000033', 'f4f4f4f4-0000-4000-8000-000000000034',
             'f5f5f5f5-0000-4000-8000-000000000035');

-- Runs a statement that should fail, and records whether it failed with this error (a LIKE pattern).
create function perm_test.expect(p_test text, p_sql text, p_error text)
returns void
language plpgsql
as $$
begin
  begin
    execute p_sql;
    insert into perm_test.results (test, passed, detail) values (p_test, false, 'it worked');
  exception when others then
    insert into perm_test.results (test, passed, detail) values (p_test, sqlerrm like p_error, sqlerrm);
  end;
end;
$$;
grant execute on function perm_test.expect(text, text, text) to anon, authenticated;

insert into perm_test.results (test, passed, detail)
select 'new accounts start on the Free plan', plan = 'free', plan
from public.profiles where id = 'f1f1f1f1-0000-4000-8000-000000000031';

insert into storage.objects (bucket_id, name) values
  ('uploads', 'f1f1f1f1-0000-4000-8000-000000000031/0a0a0a0a-0000-4000-8000-0000000000a1/model.glb'),
  ('uploads', 'f1f1f1f1-0000-4000-8000-000000000031/0a0a0a0a-0000-4000-8000-0000000000a1/thumbnail.png');

set role authenticated;
select set_config('request.jwt.claims', '{"sub":"f1f1f1f1-0000-4000-8000-000000000031","role":"authenticated"}', false);
do $$
declare v_json jsonb;
begin
  perform perm_test.expect('the Free plan can''t add offers',
    format('select public.save_drop(%L::jsonb)', jsonb_set(current_setting('t.offer')::jsonb, '{placement,lat}', '61.5')),
    'plan_offers');
  perform perm_test.expect('the Free plan can''t upload 3D models',
    $q$insert into public.assets (id, kind, source_format, model_path, thumbnail_path)
       values ('0a0a0a0a-0000-4000-8000-0000000000a1', 'model', 'glb',
               'f1f1f1f1-0000-4000-8000-000000000031/0a0a0a0a-0000-4000-8000-0000000000a1/model.glb',
               'f1f1f1f1-0000-4000-8000-000000000031/0a0a0a0a-0000-4000-8000-0000000000a1/thumbnail.png')$q$,
    'plan_models');
  perform perm_test.expect('people can''t change their own plan',
    $q$update public.profiles set plan = 'events' where id = 'f1f1f1f1-0000-4000-8000-000000000031'$q$,
    'permission denied%');

  v_json := public.my_plan();
  insert into perm_test.results (test, passed, detail)
  values ('people see their plan, what they use, and every plan',
          v_json ->> 'plan' = 'free' and jsonb_array_length(v_json -> 'plans') = 4 and (v_json ->> 'drops')::int = 0
          and (v_json -> 'plans' -> 0 ->> 'maxDrops')::int = 10, v_json::text);

  perform perm_test.expect('Free isn''t something to ask for', $q$select public.request_plan('free', 'x')$q$, 'bad_plan');
  perform perm_test.expect('a request says what it''s for', $q$select public.request_plan('business', '  ')$q$, 'note_needed');
  perform public.request_plan('plus', 'Testing');
  perform public.request_plan('business', 'Test Cafe, 1 Main St');
  insert into perm_test.results (test, passed, detail)
  values ('asking again replaces the open request',
          public.my_plan() -> 'request' ->> 'plan' = 'business' and public.my_plan() -> 'request' ->> 'status' = 'open',
          (public.my_plan() -> 'request')::text);

  perform perm_test.expect('people can''t see others'' plan requests', 'select public.plan_requests_queue()', 'not_staff');
  perform perm_test.expect('people can''t grant plans', 'select public.decide_plan_request(1, true)', 'not_staff');
  perform perm_test.expect('people can''t set plans',
    $q$select public.set_plan('f1f1f1f1-0000-4000-8000-000000000031', 'events')$q$, 'not_staff');
end $$;
reset role;
select set_config('request.jwt.claims', '', false);

set role authenticated;
select set_config('request.jwt.claims', '{"sub":"eeeeeeee-0000-4000-8000-000000000005","role":"authenticated"}', false);
do $$
declare v_request jsonb;
begin
  select j into v_request from public.plan_requests_queue() j
  where j -> 'user' ->> 'id' = 'f1f1f1f1-0000-4000-8000-000000000031';
  insert into perm_test.results (test, passed, detail)
  values ('staff see plan requests with who''s asking',
          v_request ->> 'plan' = 'business' and v_request -> 'user' ->> 'email' = 'p1@example.invalid', v_request::text);
  perform public.decide_plan_request((v_request ->> 'id')::bigint, true, 'Welcome');
end $$;
reset role;
select set_config('request.jwt.claims', '', false);

set role authenticated;
select set_config('request.jwt.claims', '{"sub":"f1f1f1f1-0000-4000-8000-000000000031","role":"authenticated"}', false);
do $$
declare v_id text; v_json jsonb;
begin
  insert into perm_test.results (test, passed, detail)
  values ('a granted request changes the plan',
          public.my_plan() ->> 'plan' = 'business' and public.my_plan() -> 'request' ->> 'status' = 'granted',
          public.my_plan()::text);

  v_id := public.save_drop(jsonb_set(jsonb_set(current_setting('t.offer')::jsonb, '{placement,lat}', '61.5'), '{offer}',
    '{"savings": "A free cookie", "terms": "", "quantity": 5, "perPerson": 1, "rarity": "common", "inQuests": false,
      "kind": "giveaway", "category": "sweets", "tradeable": false}'));
  perform set_config('t.p1offer', v_id, false);
  select j into v_json from public.my_drops() j where j ->> 'id' = v_id;
  insert into perm_test.results (test, passed, detail)
  values ('offers save their kind, category, and whether they can be traded',
          v_json -> 'offer' ->> 'kind' = 'giveaway' and v_json -> 'offer' ->> 'category' = 'sweets'
          and not (v_json -> 'offer' ->> 'tradeable')::boolean, (v_json -> 'offer')::text);
end $$;
reset role;
select set_config('request.jwt.claims', '', false);

update public.profiles set plan_until = now() - interval '1 day' where id = 'f1f1f1f1-0000-4000-8000-000000000031';
set role authenticated;
select set_config('request.jwt.claims', '{"sub":"f1f1f1f1-0000-4000-8000-000000000031","role":"authenticated"}', false);
do $$ begin
  perform perm_test.expect('a plan that has ended counts as Free',
    format('select public.save_drop(%L::jsonb)', jsonb_set(current_setting('t.offer')::jsonb, '{placement,lat}', '61.6')),
    'plan_offers');
  begin
    perform public.save_drop(jsonb_set(jsonb_set(jsonb_set(current_setting('t.offer')::jsonb, '{placement,lat}', '61.5'),
      '{id}', to_jsonb(current_setting('t.p1offer'))), '{title}', '"Renamed"'));
    insert into perm_test.results (test, passed, detail) values ('existing offers stay editable after a plan ends', true, null);
  exception when raise_exception then
    insert into perm_test.results (test, passed, detail) values ('existing offers stay editable after a plan ends', false, sqlerrm);
  end;
end $$;
reset role;
select set_config('request.jwt.claims', '', false);
update public.profiles set plan_until = null where id = 'f1f1f1f1-0000-4000-8000-000000000031';

-- B is on Free with ten drops already (above).
update public.profiles set plan = 'plus' where id = 'bbbbbbbb-0000-4000-8000-000000000002';
set role authenticated;
select set_config('request.jwt.claims', '{"sub":"bbbbbbbb-0000-4000-8000-000000000002","role":"authenticated"}', false);
do $$ begin
  begin
    perform public.save_drop(jsonb_set(current_setting('t.drop')::jsonb, '{placement,lat}', '45.3'));
    insert into perm_test.results (test, passed, detail) values ('Plus allows more drops than Free', true, null);
  exception when raise_exception then
    insert into perm_test.results (test, passed, detail) values ('Plus allows more drops than Free', false, sqlerrm);
  end;
end $$;
reset role;
select set_config('request.jwt.claims', '', false);

-- ===== Playing ============================================================
-- P1's drops, a few metres apart: an offer with two in stock, an untradeable
-- offer, two objects, and an object far away.

create function perm_test.place(p_owner uuid, p_type text, p_lat double precision, p_quantity integer default 10,
                                p_rarity text default 'common', p_tradeable boolean default true,
                                p_in_quests boolean default false)
returns text
language plpgsql
as $$
declare v_id text;
begin
  insert into public.drops (owner_id, type, title, object_id, lat, lng, time_zone, review)
  values (p_owner, p_type, 'Play test ' || p_type, 'gift', p_lat, -30.0, 'UTC', 'approved')
  returning id into v_id;
  if p_type = 'offer' then
    insert into public.offers (drop_id, savings, quantity, per_person, rarity, tradeable, in_quests)
    values (v_id, 'A test deal', p_quantity, 1, p_rarity, p_tradeable, p_in_quests);
  end if;
  return v_id;
end;
$$;

select set_config('t.o1', perm_test.place('f1f1f1f1-0000-4000-8000-000000000031', 'offer', 61.0, 2), false);
select set_config('t.o2', perm_test.place('f1f1f1f1-0000-4000-8000-000000000031', 'offer', 61.0002, 10, 'common', false), false);
select set_config('t.ob1', perm_test.place('f1f1f1f1-0000-4000-8000-000000000031', 'object', 61.0004), false);
select set_config('t.ob2', perm_test.place('f1f1f1f1-0000-4000-8000-000000000031', 'object', 61.0006), false);
select set_config('t.far', perm_test.place('f1f1f1f1-0000-4000-8000-000000000031', 'object', 62.0), false);

set role anon;
do $$
declare v_json jsonb;
begin
  perform perm_test.expect('visitors can''t capture',
    format('select public.capture(%L, 61.0, -30.0, 5)', current_setting('t.o1')), 'permission denied%');
  perform perm_test.expect('visitors can''t read the inventory', 'select 1 from public.inventory limit 1', 'permission denied%');
  v_json := public.app_nearby(61.0, -30.0, 200);
  insert into perm_test.results (test, passed, detail)
  values ('anyone can see what''s nearby, nearest first',
          jsonb_array_length(v_json -> 'drops') = 4 and v_json -> 'drops' -> 0 ->> 'id' = current_setting('t.o1')
          and v_json -> 'drops' -> 3 ->> 'id' = current_setting('t.ob2') and jsonb_typeof(v_json -> 'player') = 'null',
          v_json::text);
  perform perm_test.expect('nearby needs a real place', 'select public.app_nearby(95, 0)', 'bad_location');
end $$;
reset role;
select set_config('request.jwt.claims', '', false);

set role authenticated;
select set_config('request.jwt.claims', '{"sub":"f2f2f2f2-0000-4000-8000-000000000032","role":"authenticated"}', false);
do $$
declare v_json jsonb;
begin
  perform perm_test.expect('capturing needs a good location fix',
    format('select public.capture(%L, 61.0, -30.0, 500)', current_setting('t.o1')), 'location_unclear');
  perform perm_test.expect('capturing needs you to be there',
    format('select public.capture(%L, 61.01, -30.0, 5)', current_setting('t.o1')), 'too_far');

  v_json := public.capture(current_setting('t.o1'), 61.0, -30.0, 5);
  perform set_config('t.i1', v_json -> 'item' ->> 'id', false);
  insert into perm_test.results (test, passed, detail)
  values ('capturing an offer puts it in the inventory and earns XP',
          v_json -> 'item' ->> 'status' = 'held' and (v_json ->> 'xp')::int = 20 and (v_json -> 'player' ->> 'xp')::int = 20
          and exists (select 1 from public.my_inventory() j where j ->> 'id' = current_setting('t.i1')), v_json::text);
  perform perm_test.expect('each person captures an offer up to its per-person limit',
    format('select public.capture(%L, 61.0, -30.0, 5)', current_setting('t.o1')), 'already_captured');

  v_json := public.capture(current_setting('t.ob1'), 61.0004, -30.0, 5);
  perform set_config('t.i2', v_json -> 'item' ->> 'id', false);
  insert into perm_test.results (test, passed, detail)
  values ('an object earns less XP than an offer', (v_json ->> 'xp')::int = 10, v_json ->> 'xp');
  perform perm_test.expect('captures can''t be more than 250 km/h apart',
    format('select public.capture(%L, 62.0, -30.0, 5)', current_setting('t.far')), 'moving_too_fast');

  v_json := public.capture(current_setting('t.o2'), 61.0002, -30.0, 5);
  perform set_config('t.i3', v_json -> 'item' ->> 'id', false);

  perform perm_test.expect('handles are 3 to 20 letters, digits or _', $q$select public.set_handle('no')$q$, 'bad_handle');
  perform public.set_handle('Player_One');
  insert into perm_test.results (test, passed, detail)
  values ('people choose a handle, kept in lowercase',
          public.my_player() ->> 'handle' = 'player_one' and (public.my_player() ->> 'xp')::int = 50
          and (public.my_player() ->> 'level')::int = 1, public.my_player()::text);
end $$;
reset role;
select set_config('request.jwt.claims', '', false);

set role authenticated;
select set_config('request.jwt.claims', '{"sub":"f3f3f3f3-0000-4000-8000-000000000033","role":"authenticated"}', false);
do $$
declare v_json jsonb;
begin
  perform perm_test.expect('handles are unique', $q$select public.set_handle('player_one')$q$, 'handle_taken');
  perform public.set_handle('player_two');
  v_json := public.capture(current_setting('t.o1'), 61.0, -30.0, 5);
  perform set_config('t.i4', v_json -> 'item' ->> 'id', false);
  insert into perm_test.results (test, passed, detail)
  values ('players see only their own inventory',
          not exists (select 1 from public.my_inventory() j
                      where j ->> 'id' in (current_setting('t.i1'), current_setting('t.i2'), current_setting('t.i3'))), null);
  perform public.set_for_trade(current_setting('t.i4')::uuid, true);
end $$;
reset role;
select set_config('request.jwt.claims', '', false);

set role authenticated;
select set_config('request.jwt.claims', '{"sub":"f4f4f4f4-0000-4000-8000-000000000034","role":"authenticated"}', false);
do $$ begin
  perform perm_test.expect('nobody can capture an offer that''s run out',
    format('select public.capture(%L, 61.0, -30.0, 5)', current_setting('t.o1')), 'sold_out');
end $$;
reset role;
select set_config('request.jwt.claims', '{"sub":"f1f1f1f1-0000-4000-8000-000000000031","role":"authenticated"}', false);
set role authenticated;
do $$ begin
  perform perm_test.expect('businesses can''t capture their own drops',
    format('select public.capture(%L, 61.0002, -30.0, 5)', current_setting('t.o2')), 'own_drop');
end $$;
reset role;
select set_config('request.jwt.claims', '', false);

-- Redeeming.
set role authenticated;
select set_config('request.jwt.claims', '{"sub":"f2f2f2f2-0000-4000-8000-000000000032","role":"authenticated"}', false);
do $$
declare v_a jsonb; v_b jsonb;
begin
  v_a := public.start_redemption(current_setting('t.i1')::uuid);
  v_b := public.start_redemption(current_setting('t.i1')::uuid);
  perform set_config('t.code', v_a ->> 'code', false);
  insert into perm_test.results (test, passed, detail)
  values ('redeeming shows a 6-digit code, the same one until it''s used',
          v_a ->> 'code' ~ '^[0-9]{6}$' and v_a ->> 'code' = v_b ->> 'code', v_a::text);
  perform perm_test.expect('only offers are redeemed',
    format('select public.start_redemption(%L)', current_setting('t.i2')), 'not_an_offer');
  perform perm_test.expect('players can''t confirm their own code',
    format('select public.confirm_redemption(%L)', current_setting('t.code')), 'code_not_found');
end $$;
reset role;
select set_config('request.jwt.claims', '{"sub":"f4f4f4f4-0000-4000-8000-000000000034","role":"authenticated"}', false);
set role authenticated;
do $$ begin
  perform perm_test.expect('a code only works at its own business',
    format('select public.confirm_redemption(%L)', current_setting('t.code')), 'code_not_found');
end $$;
reset role;
select set_config('request.jwt.claims', '{"sub":"f1f1f1f1-0000-4000-8000-000000000031","role":"authenticated"}', false);
set role authenticated;
do $$
declare v_json jsonb;
begin
  v_json := public.confirm_redemption(substr(current_setting('t.code'), 1, 3) || ' ' || substr(current_setting('t.code'), 4));
  insert into perm_test.results (test, passed, detail)
  values ('the business types in the code, and that redeems the offer',
          v_json ->> 'player' = 'player_one'
          and (select (j -> 'stats' ->> 'redeemed')::int from public.my_drops() j where j ->> 'id' = current_setting('t.o1')) = 1
          and (select (j -> 'stats' ->> 'captures')::int from public.my_drops() j where j ->> 'id' = current_setting('t.o1')) = 2,
          v_json::text);
  perform perm_test.expect('a code works once',
    format('select public.confirm_redemption(%L)', current_setting('t.code')), 'code_not_found');
  insert into perm_test.results (test, passed, detail)
  values ('businesses see their redemptions',
          exists (select 1 from public.recent_redemptions() j where j ->> 'player' = 'player_one'), null);
end $$;
reset role;
select set_config('request.jwt.claims', '', false);

-- Trading.
set role authenticated;
select set_config('request.jwt.claims', '{"sub":"f2f2f2f2-0000-4000-8000-000000000032","role":"authenticated"}', false);
do $$
declare v_shelf jsonb; v_trade jsonb;
begin
  insert into perm_test.results (test, passed, detail)
  values ('a redeemed offer stays in the inventory as redeemed',
          (select j ->> 'status' from public.my_inventory() j where j ->> 'id' = current_setting('t.i1')) = 'redeemed', null);

  v_shelf := public.player_shelf('Player_Two');
  insert into perm_test.results (test, passed, detail)
  values ('players see only what others put up for trade',
          jsonb_array_length(v_shelf -> 'items') = 1 and v_shelf -> 'items' -> 0 ->> 'id' = current_setting('t.i4')
          and v_shelf -> 'captures' is null, v_shelf::text);
  perform perm_test.expect('an offer its business made untradeable can''t go up for trade',
    format('select public.set_for_trade(%L, true)', current_setting('t.i3')), 'not_tradeable');
  perform perm_test.expect('an untradeable offer can''t be left on the map',
    format('select public.drop_item(%L, 61.0, -30.0)', current_setting('t.i3')), 'not_tradeable');
  perform perm_test.expect('an untradeable offer can''t be offered in a trade',
    format('select public.propose_trade(%L, array[%L]::uuid[], array[%L]::uuid[])',
           'player_two', current_setting('t.i3'), current_setting('t.i4')), 'item_not_available');
  perform perm_test.expect('nobody trades with themselves',
    format('select public.propose_trade(%L, array[%L]::uuid[])', 'player_one', current_setting('t.i2')), 'trade_with_self');

  v_trade := public.propose_trade('player_two', array[current_setting('t.i2')]::uuid[], array[current_setting('t.i4')]::uuid[]);
  perform set_config('t.trade', v_trade ->> 'id', false);
end $$;
reset role;
select set_config('request.jwt.claims', '', false);

set role authenticated;
select set_config('request.jwt.claims', '{"sub":"f3f3f3f3-0000-4000-8000-000000000033","role":"authenticated"}', false);
do $$
declare v_json jsonb;
begin
  insert into perm_test.results (test, passed, detail)
  values ('people see trades offered to them',
          exists (select 1 from public.my_trades() j
                  where j ->> 'id' = current_setting('t.trade') and not (j ->> 'fromMe')::boolean
                    and j -> 'other' ->> 'handle' = 'player_one'), null);
  v_json := public.answer_trade(current_setting('t.trade')::uuid, true);
  insert into perm_test.results (test, passed, detail)
  values ('accepting a trade swaps the items',
          v_json ->> 'status' = 'accepted'
          and exists (select 1 from public.my_inventory() j where j ->> 'id' = current_setting('t.i2') and j ->> 'source' = 'trade')
          and not exists (select 1 from public.my_inventory() j where j ->> 'id' = current_setting('t.i4')), v_json::text);
end $$;
reset role;
select set_config('request.jwt.claims', '', false);

set role authenticated;
select set_config('request.jwt.claims', '{"sub":"f2f2f2f2-0000-4000-8000-000000000032","role":"authenticated"}', false);
do $$
declare v_trade jsonb;
begin
  insert into perm_test.results (test, passed, detail)
  values ('a traded offer can be redeemed by its new owner',
          public.start_redemption(current_setting('t.i4')::uuid) ->> 'code' ~ '^[0-9]{6}$', null);

  v_trade := public.propose_trade('player_two', array[current_setting('t.i4')]::uuid[]);
  perform set_config('t.trade2', v_trade ->> 'id', false);
  perform public.discard_item(current_setting('t.i4')::uuid);
  insert into perm_test.results (test, passed, detail)
  values ('a discarded offer goes back in stock',
          (public.public_drop(current_setting('t.o1')) -> 'offer' ->> 'remaining')::int = 1,
          public.public_drop(current_setting('t.o1')) -> 'offer' ->> 'remaining');
end $$;
reset role;
select set_config('request.jwt.claims', '', false);

set role authenticated;
select set_config('request.jwt.claims', '{"sub":"f3f3f3f3-0000-4000-8000-000000000033","role":"authenticated"}', false);
do $$ begin
  insert into perm_test.results (test, passed, detail)
  values ('a trade fails if an item in it was used since',
          public.answer_trade(current_setting('t.trade2')::uuid, true) ->> 'status' = 'failed', null);
end $$;
reset role;
select set_config('request.jwt.claims', '', false);

-- Leaving items on the map.
set role authenticated;
select set_config('request.jwt.claims', '{"sub":"f2f2f2f2-0000-4000-8000-000000000032","role":"authenticated"}', false);
do $$
declare v_json jsonb;
begin
  v_json := public.capture(current_setting('t.ob2'), 61.0006, -30.0, 5);
  perform set_config('t.i5', v_json -> 'item' ->> 'id', false);
  perform public.drop_item(current_setting('t.i5')::uuid, 61.0006, -30.0);
  insert into perm_test.results (test, passed, detail)
  values ('an item left on the map shows as left',
          (select j ->> 'status' from public.my_inventory() j where j ->> 'id' = current_setting('t.i5')) = 'dropped', null);
end $$;
reset role;
select set_config('request.jwt.claims', '', false);

set role authenticated;
select set_config('request.jwt.claims', '{"sub":"f3f3f3f3-0000-4000-8000-000000000033","role":"authenticated"}', false);
do $$
declare v_json jsonb;
begin
  insert into perm_test.results (test, passed, detail)
  values ('players see items left on the map nearby',
          exists (select 1 from jsonb_array_elements(public.app_nearby(61.0006, -30.0, 100) -> 'items') x
                  where x ->> 'id' = current_setting('t.i5')), null);
  perform perm_test.expect('picking up needs you to be there',
    format('select public.pick_up_item(%L, 61.01, -30.0, 5)', current_setting('t.i5')), 'too_far');
  v_json := public.pick_up_item(current_setting('t.i5')::uuid, 61.0006, -30.0, 5);
  insert into perm_test.results (test, passed, detail)
  values ('anyone nearby can pick it up, for 5 XP',
          (v_json ->> 'xp')::int = 5 and v_json -> 'item' ->> 'status' = 'held', v_json::text);
  perform public.drop_item(current_setting('t.i5')::uuid, 61.0006, -30.0);
end $$;
reset role;
select set_config('request.jwt.claims', '', false);

update public.loose_items set expires_at = now() - interval '1 minute' where item_id = current_setting('t.i5')::uuid;
select private.play_upkeep();
insert into perm_test.results (test, passed, detail)
select 'an item nobody picks up goes back to whoever left it',
       owner_id = 'f3f3f3f3-0000-4000-8000-000000000033' and status = 'held', status
from public.inventory where id = current_setting('t.i5')::uuid;

insert into perm_test.results (test, passed, detail)
values ('levels need 100 XP, then 300, then 600',
        public.level_for(0) = 1 and public.level_for(99) = 1 and public.level_for(100) = 2 and public.level_for(299) = 2
        and public.level_for(300) = 3 and public.level_for(600) = 4 and public.xp_for_level(3) = 300, null);

insert into perm_test.results (test, passed, detail)
select 'rarer offers show up less often',
       count(*) filter (where private.rarity_roll('d' || i, 'common', null)) = 1000
       and count(*) filter (where private.rarity_roll('d' || i, 'uncommon', null)) between 520 and 680
       and count(*) filter (where private.rarity_roll('d' || i, 'rare', null)) between 220 and 380,
       count(*) filter (where private.rarity_roll('d' || i, 'uncommon', null)) || ' uncommon, '
       || count(*) filter (where private.rarity_roll('d' || i, 'rare', null)) || ' rare of 1000'
from generate_series(1, 1000) i;

-- ===== Playing a quest, and themes ========================================

select set_config('t.s1', perm_test.place('f1f1f1f1-0000-4000-8000-000000000031', 'offer', 63.0, 10, 'common', true, true), false);
select set_config('t.s2', perm_test.place('f4f4f4f4-0000-4000-8000-000000000034', 'offer', 63.0003, 10, 'uncommon', true, true), false);
select set_config('t.s3', perm_test.place('f5f5f5f5-0000-4000-8000-000000000035', 'offer', 63.0006, 10, 'rare', true, true), false);
select set_config('t.c1', perm_test.place('f1f1f1f1-0000-4000-8000-000000000031', 'offer', 64.0, 10, 'common', true, true), false);
select set_config('t.c2', perm_test.place('f4f4f4f4-0000-4000-8000-000000000034', 'offer', 64.0003, 10, 'uncommon', true, true), false);
select set_config('t.c3', perm_test.place('f5f5f5f5-0000-4000-8000-000000000035', 'offer', 64.0006, 10, 'rare', true, true), false);
update public.offers set category = 'coffee'
where drop_id in (current_setting('t.c1'), current_setting('t.c2'), current_setting('t.c3'));
select private.refresh_quests();
select set_config('t.quest', perm_test.quest_of(current_setting('t.s1')), false);
select set_config('t.cquest', perm_test.quest_of(current_setting('t.c1')), false);

insert into perm_test.results (test, passed, detail)
select 'a quest of one kind of business gets its theme',
       q.theme = 'coffee' and q.name like 'Coffee crawl: %' and q.stage_count = 3
       and public.quest_to_json(q) ->> 'themeName' = 'Coffee crawl', q.name
from public.quests q where q.id = current_setting('t.cquest');
insert into perm_test.results (test, passed, detail)
select 'other quests are mixed', q.theme is null and q.stage_count = 3, q.name
from public.quests q where q.id = current_setting('t.quest');

update public.player_stats set last_capture_at = null;
set role authenticated;
select set_config('request.jwt.claims', '{"sub":"f2f2f2f2-0000-4000-8000-000000000032","role":"authenticated"}', false);
do $$
declare v_json jsonb; v_near jsonb;
begin
  perform perm_test.expect('later quest stages are locked until the one before is done',
    format('select public.capture(%L, 63.0003, -30.0, 5)', current_setting('t.s2')), 'quest_locked');
  v_near := public.app_nearby(63.0003, -30.0, 100);
  insert into perm_test.results (test, passed, detail)
  values ('locked quest stages don''t show up',
          not exists (select 1 from jsonb_array_elements(v_near -> 'drops') x
                      where x ->> 'id' in (current_setting('t.s2'), current_setting('t.s3')))
          and exists (select 1 from jsonb_array_elements(v_near -> 'drops') x where x ->> 'id' = current_setting('t.s1')),
          v_near::text);

  v_json := public.capture(current_setting('t.s1'), 63.0, -30.0, 5);
  insert into perm_test.results (test, passed, detail)
  values ('capturing the first stage starts the quest',
          (v_json -> 'quest' ->> 'stage')::int = 1 and (v_json ->> 'xp')::int = 45, v_json::text);
  perform public.capture(current_setting('t.s2'), 63.0003, -30.0, 5);
  v_json := public.capture(current_setting('t.s3'), 63.0006, -30.0, 5);
  insert into perm_test.results (test, passed, detail)
  values ('finishing a quest earns a bonus and points',
          (v_json -> 'quest' ->> 'completed')::boolean and (v_json ->> 'xp')::int = 475 and (v_json ->> 'points')::int = 100,
          v_json::text);
  insert into perm_test.results (test, passed, detail)
  values ('players see the quests they''ve played',
          exists (select 1 from public.my_quests() j
                  where j ->> 'id' = current_setting('t.quest') and j -> 'progress' ->> 'completedAt' is not null), null);
end $$;
reset role;
select set_config('request.jwt.claims', '', false);

update public.offers set category = 'food' where drop_id = current_setting('t.c2');
select private.refresh_quests();
insert into perm_test.results (test, passed, detail)
select 'a themed quest retires when an offer changes its kind of business',
       status = 'retired' and retired_reason = 'Stage 2 is a different kind of business now.', retired_reason
from public.quests where id = current_setting('t.cquest');

-- ===== Events =============================================================

update public.profiles set plan = 'events' where id = 'f4f4f4f4-0000-4000-8000-000000000034';
select set_config('t.e1', perm_test.place('f4f4f4f4-0000-4000-8000-000000000034', 'object', 65.0), false);
select set_config('t.e2', perm_test.place('f4f4f4f4-0000-4000-8000-000000000034', 'object', 65.0003), false);
select set_config('t.er', perm_test.place('f4f4f4f4-0000-4000-8000-000000000034', 'offer', 65.0006, 5), false);
select set_config('t.event_payload', jsonb_build_object(
  'title', 'Test trail', 'description', 'Two stops.', 'format', 'trail',
  'startsAt', now() - interval '1 hour', 'endsAt', now() + interval '1 day',
  'stopXp', 30, 'bonusXp', 200, 'bonusPoints', 40, 'rewardDropId', current_setting('t.er'),
  'stops', jsonb_build_array(current_setting('t.e1'), current_setting('t.e2')))::text, false);

set role authenticated;
select set_config('request.jwt.claims', '{"sub":"f1f1f1f1-0000-4000-8000-000000000031","role":"authenticated"}', false);
do $$ begin
  perform perm_test.expect('events need the Events plan',
    format('select public.save_event(%L::jsonb)', jsonb_set(current_setting('t.event_payload')::jsonb, '{stops}',
           jsonb_build_array(current_setting('t.o1'), current_setting('t.o2')))), 'plan_events');
end $$;
reset role;
select set_config('request.jwt.claims', '{"sub":"f4f4f4f4-0000-4000-8000-000000000034","role":"authenticated"}', false);
set role authenticated;
do $$
declare v_id text;
begin
  perform perm_test.expect('an event''s stops are the business''s own drops',
    format('select public.save_event(%L::jsonb)', jsonb_set(current_setting('t.event_payload')::jsonb, '{stops}',
           jsonb_build_array(current_setting('t.e1'), current_setting('t.o1')))), 'event_stops');
  v_id := public.save_event(current_setting('t.event_payload')::jsonb);
  perform set_config('t.event', v_id, false);
  insert into perm_test.results (test, passed, detail)
  values ('businesses on the Events plan make events from their drops',
          exists (select 1 from public.my_events() j where j ->> 'id' = v_id and jsonb_array_length(j -> 'stops') = 2), null);
end $$;
reset role;
select set_config('request.jwt.claims', '', false);

update public.player_stats set last_capture_at = null;
set role authenticated;
select set_config('request.jwt.claims', '{"sub":"f2f2f2f2-0000-4000-8000-000000000032","role":"authenticated"}', false);
do $$
declare v_json jsonb;
begin
  v_json := public.capture(current_setting('t.e2'), 65.0003, -30.0, 5);
  insert into perm_test.results (test, passed, detail)
  values ('a trail''s stops count only in order',
          jsonb_array_length(v_json -> 'events') = 0 and jsonb_typeof(v_json -> 'item') = 'object', v_json::text);
  perform public.capture(current_setting('t.e1'), 65.0, -30.0, 5);
  v_json := public.capture(current_setting('t.e2'), 65.0003, -30.0, 5);
  insert into perm_test.results (test, passed, detail)
  values ('finishing an event earns its bonus, points and reward',
          (v_json -> 'events' -> 0 ->> 'completed')::boolean and (v_json ->> 'xp')::int = 230
          and (v_json ->> 'points')::int = 40 and jsonb_array_length(v_json -> 'rewards') = 1
          and jsonb_typeof(v_json -> 'item') = 'null', v_json::text);
  insert into perm_test.results (test, passed, detail)
  values ('the app sees events nearby, with the player''s progress',
          exists (select 1 from jsonb_array_elements(public.app_nearby(65.0, -30.0, 200) -> 'events') x
                  where x ->> 'id' = current_setting('t.event') and x -> 'progress' ->> 'completedAt' is not null), null);
end $$;
reset role;
select set_config('request.jwt.claims', '{"sub":"f4f4f4f4-0000-4000-8000-000000000034","role":"authenticated"}', false);
set role authenticated;
do $$ begin
  insert into perm_test.results (test, passed, detail)
  values ('businesses see how many players finished their events',
          (select (j ->> 'finished')::int from public.my_events() j where j ->> 'id' = current_setting('t.event')) = 1, null);
end $$;
reset role;
select set_config('request.jwt.claims', '', false);
set role anon;
do $$ begin
  insert into perm_test.results (test, passed, detail)
  values ('anyone can open an event', public.public_event(current_setting('t.event')) ->> 'title' = 'Test trail', null);
end $$;
reset role;
select set_config('request.jwt.claims', '', false);

-- Test quests go before their businesses do.
delete from public.quests q
where exists (select 1 from public.quest_stages s join public.drops d on d.id = s.drop_id
              where s.quest_id = q.id
                and d.owner_id in ('f1f1f1f1-0000-4000-8000-000000000031', 'f4f4f4f4-0000-4000-8000-000000000034',
                                   'f5f5f5f5-0000-4000-8000-000000000035'));
delete from storage.objects
where bucket_id = 'uploads' and name like 'f1f1f1f1-0000-4000-8000-000000000031/%';

-- A test whose check finds no row records nothing, so make sure none went missing.
-- Update this number when adding or removing a test.
insert into perm_test.results (test, passed, detail)
select 'every test recorded a result', count(*) = 228, count(*)::text || ' of 228'
from perm_test.results;

-- ===== Clean up, then show the results ====================================
drop table if exists pg_temp.perm_test_results;
create temp table perm_test_results as select * from perm_test.results;
delete from auth.users where id in (
  'aaaaaaaa-0000-4000-8000-000000000001', 'bbbbbbbb-0000-4000-8000-000000000002',
  'cccccccc-0000-4000-8000-000000000003', 'dddddddd-0000-4000-8000-000000000004',
  'eeeeeeee-0000-4000-8000-000000000005', 'ffffffff-0000-4000-8000-000000000006',
  'abababab-0000-4000-8000-000000000007', 'cdcdcdcd-0000-4000-8000-000000000008',
  'a1a1a1a1-0000-4000-8000-000000000011', 'a2a2a2a2-0000-4000-8000-000000000012',
  'a3a3a3a3-0000-4000-8000-000000000013', 'a4a4a4a4-0000-4000-8000-000000000014',
  'a5a5a5a5-0000-4000-8000-000000000015', 'b1b1b1b1-0000-4000-8000-000000000021',
  'b2b2b2b2-0000-4000-8000-000000000022', 'f1f1f1f1-0000-4000-8000-000000000031',
  'f2f2f2f2-0000-4000-8000-000000000032', 'f3f3f3f3-0000-4000-8000-000000000033',
  'f4f4f4f4-0000-4000-8000-000000000034', 'f5f5f5f5-0000-4000-8000-000000000035');
delete from public.moderation_events
where drop_id in (current_setting('t.d1'), current_setting('t.a1'), current_setting('t.a_open'), current_setting('t.f1'),
                  current_setting('t.a_paused'), current_setting('t.a_link'), current_setting('t.a_over'),
                  current_setting('t.g1'), current_setting('t.g2'), current_setting('t.g3'), current_setting('t.g4'),
                  current_setting('t.g5'), current_setting('t.h1'), current_setting('t.h2'), current_setting('t.b_old'),
                  current_setting('t.qc2'), current_setting('t.j1'), current_setting('t.j2'), current_setting('t.j3'),
                  current_setting('t.j4'));
delete from public.reports
where drop_id in (current_setting('t.a1'), current_setting('t.a_open'), current_setting('t.b_old'))
   or (drop_id is null and contact = 'owner@example.invalid');
drop schema perm_test cascade;

select n, passed, test, detail from perm_test_results order by n;
