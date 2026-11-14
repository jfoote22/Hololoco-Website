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
update public.profiles set display_name = 'Tester', adult_confirmed_at = now()
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
update public.profiles set display_name = 'Test Bakery', adult_confirmed_at = now() where id = 'abababab-0000-4000-8000-000000000007';
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

-- A test whose check finds no row records nothing, so make sure none went missing.
-- Update this number when adding or removing a test.
insert into perm_test.results (test, passed, detail)
select 'every test recorded a result', count(*) = 125, count(*)::text || ' of 125'
from perm_test.results;

-- ===== Clean up, then show the results ====================================
drop table if exists pg_temp.perm_test_results;
create temp table perm_test_results as select * from perm_test.results;
delete from auth.users where id in (
  'aaaaaaaa-0000-4000-8000-000000000001', 'bbbbbbbb-0000-4000-8000-000000000002',
  'cccccccc-0000-4000-8000-000000000003', 'dddddddd-0000-4000-8000-000000000004',
  'eeeeeeee-0000-4000-8000-000000000005', 'ffffffff-0000-4000-8000-000000000006',
  'abababab-0000-4000-8000-000000000007', 'cdcdcdcd-0000-4000-8000-000000000008');
delete from public.moderation_events
where drop_id in (current_setting('t.d1'), current_setting('t.a1'), current_setting('t.a_open'), current_setting('t.f1'),
                  current_setting('t.a_paused'), current_setting('t.a_link'), current_setting('t.a_over'),
                  current_setting('t.g1'), current_setting('t.g2'), current_setting('t.g3'), current_setting('t.g4'),
                  current_setting('t.g5'), current_setting('t.h1'), current_setting('t.h2'), current_setting('t.b_old'));
delete from public.reports
where drop_id in (current_setting('t.a1'), current_setting('t.a_open'), current_setting('t.b_old'))
   or (drop_id is null and contact = 'owner@example.invalid');
drop schema perm_test cascade;

select n, passed, test, detail from perm_test_results order by n;
