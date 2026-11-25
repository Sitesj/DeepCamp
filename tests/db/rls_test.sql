-- Deer Camp database tests: camp-code sign-in, constraints, triggers and RLS.
-- Run with: tests/db/run.sh   (each failed expectation raises an exception)
--
-- Phones (Supabase auth users):  A = admin's phone, B = Mike's, C = John's, D = a stranger's
-- Hunters (profiles):            Al (admin), Mike, John
\set ON_ERROR_STOP on
set client_min_messages = notice;

create or replace function pg_temp.act_as(uid text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', uid, false);
  execute 'set role authenticated';
end $$;

create or replace function pg_temp.expect_fail(sql text, label text) returns void language plpgsql as $$
begin
  begin
    execute sql;
  exception when others then
    raise notice 'ok (rejected): % -> %', label, sqlerrm;
    return;
  end;
  raise exception 'EXPECTED FAILURE BUT SUCCEEDED: %', label;
end $$;

create or replace function pg_temp.expect(cond boolean, label text) returns void language plpgsql as $$
begin
  if cond is not true then raise exception 'EXPECTATION FAILED: %', label; end if;
  raise notice 'ok: %', label;
end $$;

-- ---- Setup, as the camp administrator does once in the SQL Editor
insert into auth.users (id) values
  ('00000000-0000-4000-8000-00000000000a'), ('00000000-0000-4000-8000-00000000000b'),
  ('00000000-0000-4000-8000-00000000000c'), ('00000000-0000-4000-8000-00000000000d');
insert into public.profiles (id, display_name, is_admin, is_active) values
  ('a0000000-0000-4000-8000-000000000001', 'Al', true, true),
  ('b0000000-0000-4000-8000-000000000002', 'Mike', false, true),
  ('c0000000-0000-4000-8000-000000000003', 'John', false, true);
select public.set_camp_code('482913');
select pg_temp.expect((select code_hash <> '482913' and code_hash like '$2%' from camp_settings), 'camp code stored only as a bcrypt hash');
select pg_temp.expect((select count(*) from profiles) = 3, 'new phones do not create profiles');

-- ---- Joining the camp
select pg_temp.act_as('00000000-0000-4000-8000-00000000000a');
select pg_temp.expect((select count(*) from profiles) = 0, 'phone not joined yet sees no hunters');
select pg_temp.expect((select count(*) from stands) = 0, 'phone not joined yet sees no stands');
select pg_temp.expect(public.camp_roster('111111') ->> 'error' = 'wrong', 'wrong camp code gives no hunter list');
select pg_temp.expect(jsonb_array_length(public.camp_roster(' 482913 ') -> 'hunters') = 3, 'right camp code lists the hunters');
select pg_temp.expect((public.join_camp('482913', 'a0000000-0000-4000-8000-000000000001') ->> 'ok')::boolean, 'admin phone joins as Al');
select pg_temp.expect(public.whoami() -> 'hunter' ->> 'display_name' = 'Al', 'whoami');
reset role;

select pg_temp.act_as('00000000-0000-4000-8000-00000000000b');
select pg_temp.expect((public.join_camp('482913', 'b0000000-0000-4000-8000-000000000002') ->> 'ok')::boolean, 'Mike joins on his phone');
reset role;
select pg_temp.act_as('00000000-0000-4000-8000-00000000000c');
select pg_temp.expect((public.join_camp('482913', 'c0000000-0000-4000-8000-000000000003') ->> 'ok')::boolean, 'John joins on his phone');
reset role;

-- A stranger with the code cannot take a name already in use
select pg_temp.act_as('00000000-0000-4000-8000-00000000000d');
select pg_temp.expect(public.join_camp('482913', 'b0000000-0000-4000-8000-000000000002') ->> 'error' = 'in_use', 'name in use on another phone cannot be taken');
select pg_temp.expect((select bool_and((h ->> 'in_use')::boolean) from jsonb_array_elements(public.camp_roster('482913') -> 'hunters') h), 'roster shows names in use');
select pg_temp.expect(public.whoami() -> 'hunter' = 'null'::jsonb, 'stranger is not signed in as anyone');
select pg_temp.expect_fail($$insert into hunting_sessions (id, hunter_id, stand_id, started_at)
  values (gen_random_uuid(), 'b0000000-0000-4000-8000-000000000002', gen_random_uuid(), now())$$, 'unlinked phone cannot write');
-- Guessing the code locks the phone out after 5 wrong tries
select public.camp_roster('000000'); select public.camp_roster('000001'); select public.camp_roster('000002');
select public.camp_roster('000003'); select public.camp_roster('000004');
select pg_temp.expect(public.camp_roster('482913') ->> 'error' = 'locked', 'locked out after 5 wrong codes (even the right code)');
select pg_temp.expect_fail($$select * from camp_settings$$, 'camp code hash cannot be read');
select pg_temp.expect_fail($$select * from hunter_devices$$, 'phone links cannot be read directly');
select pg_temp.expect_fail($$select public.set_camp_code('999999')$$, 'non-admin cannot change the camp code');
reset role;

-- ---- Admin creates stands
select pg_temp.act_as('00000000-0000-4000-8000-00000000000a');
insert into stands (id, name, latitude, longitude) values
  ('11111111-1111-4111-8111-111111111111', 'North Ridge', 38.5000, -90.5000),
  ('22222222-2222-4222-8222-222222222222', 'Creek Stand', 38.5050, -90.4900);
reset role;

-- ---- Hunters cannot manage stands or hunters
select pg_temp.act_as('00000000-0000-4000-8000-00000000000b');
select pg_temp.expect_fail($$insert into stands (name, latitude, longitude) values ('Sneaky', 1, 1)$$, 'hunter cannot add stand');
update stands set name = 'Renamed' where id = '11111111-1111-4111-8111-111111111111';
select pg_temp.expect((select name from stands where id = '11111111-1111-4111-8111-111111111111') = 'North Ridge', 'hunter update of stand has no effect');
update profiles set is_admin = true where id = public.current_hunter_id();
select pg_temp.expect((select not is_admin from profiles where id = public.current_hunter_id()), 'hunter cannot promote self');
select pg_temp.expect_fail($$insert into profiles (display_name, is_active) values ('Fake', true)$$, 'hunter cannot add hunters');
select pg_temp.expect_fail($$select public.release_hunter('c0000000-0000-4000-8000-000000000003')$$, 'hunter cannot release names');
select pg_temp.expect_fail($$select public.hunter_list()$$, 'hunter cannot see phone links');
reset role;

-- ---- Mike records a session, a sighting and a gunshot (as the app does: upsert)
select pg_temp.act_as('00000000-0000-4000-8000-00000000000b');
insert into hunting_sessions (id, hunter_id, stand_id, started_at, stand_latitude, stand_longitude)
values ('33333333-3333-4333-8333-333333333333', 'b0000000-0000-4000-8000-000000000002',
        '11111111-1111-4111-8111-111111111111', '2026-11-20T11:00:00Z', 38.5, -90.5);

insert into deer_sightings (id, hunter_id, stand_id, session_id, observed_at, first_seen_direction,
  first_seen_bearing, distance_range, distance_min_yards, distance_max_yards, heading_direction,
  heading_bearing, quantity, doe_count, deer_type, stand_latitude, stand_longitude, est_latitude, est_longitude, status)
values ('44444444-4444-4444-8444-444444444444', 'b0000000-0000-4000-8000-000000000002',
  '11111111-1111-4111-8111-111111111111', '33333333-3333-4333-8333-333333333333',
  '2026-11-20T12:12:00Z', 'NE', 45, '50-75', 50, 75, 'SW', 225, 2, 2, 'doe', 38.5, -90.5, 38.5004, -90.4995, 'active');

-- Idempotent re-upload of the identical record (same UUID) must not duplicate or fail
insert into deer_sightings (id, hunter_id, stand_id, session_id, observed_at, first_seen_direction,
  first_seen_bearing, distance_range, distance_min_yards, distance_max_yards, heading_direction,
  heading_bearing, quantity, doe_count, deer_type, stand_latitude, stand_longitude, est_latitude, est_longitude, status)
values ('44444444-4444-4444-8444-444444444444', 'b0000000-0000-4000-8000-000000000002',
  '11111111-1111-4111-8111-111111111111', '33333333-3333-4333-8333-333333333333',
  '2026-11-20T12:12:00Z', 'NE', 45, '50-75', 50, 75, 'SW', 225, 2, 2, 'doe', 38.5, -90.5, 38.5004, -90.4995, 'active')
on conflict (id) do update set
  hunter_id = excluded.hunter_id, stand_id = excluded.stand_id, session_id = excluded.session_id,
  observed_at = excluded.observed_at, first_seen_direction = excluded.first_seen_direction,
  first_seen_bearing = excluded.first_seen_bearing, distance_range = excluded.distance_range,
  quantity = excluded.quantity, deer_type = excluded.deer_type, status = excluded.status;
select pg_temp.expect((select count(*) from deer_sightings) = 1, 'duplicate upload is idempotent');

insert into gunshot_reports (id, hunter_id, stand_id, session_id, observed_at, direction, bearing,
  stand_latitude, stand_longitude)
values ('55555555-5555-4555-8555-555555555555', 'b0000000-0000-4000-8000-000000000002',
  '11111111-1111-4111-8111-111111111111', '33333333-3333-4333-8333-333333333333',
  '2026-11-20T12:28:00Z', 'NW', 315, 38.5, -90.5);

-- Bad data rejected by constraints
select pg_temp.expect_fail($$insert into deer_sightings (id, hunter_id, stand_id, session_id, observed_at,
  first_seen_direction, first_seen_bearing, distance_range, distance_min_yards, distance_max_yards,
  quantity, doe_count, deer_type, stand_latitude, stand_longitude)
  values (gen_random_uuid(), public.current_hunter_id(), '11111111-1111-4111-8111-111111111111',
  '33333333-3333-4333-8333-333333333333', now(), 'NE', 90, '50-75', 50, 75, 1, 1, 'doe', 38.5, -90.5)$$,
  'bearing must match direction');
select pg_temp.expect_fail($$insert into deer_sightings (id, hunter_id, stand_id, session_id, observed_at,
  first_seen_direction, first_seen_bearing, distance_range, distance_min_yards, distance_max_yards,
  quantity, doe_count, deer_type, stand_latitude, stand_longitude)
  values (gen_random_uuid(), public.current_hunter_id(), '11111111-1111-4111-8111-111111111111',
  '33333333-3333-4333-8333-333333333333', now(), 'NE', 45, '50-75', 50, 75, 0, 0, 'doe', 38.5, -90.5)$$,
  'quantity must be at least 1');

-- Mixed groups: 3 does, 1 buck, 2 fawns in one sighting
insert into deer_sightings (id, hunter_id, stand_id, session_id, observed_at, first_seen_direction,
  first_seen_bearing, distance_range, distance_min_yards, distance_max_yards, quantity,
  buck_count, doe_count, fawn_count, unknown_count, deer_type, stand_latitude, stand_longitude)
values ('77777777-7777-4777-8777-777777777777', public.current_hunter_id(), '11111111-1111-4111-8111-111111111111',
  '33333333-3333-4333-8333-333333333333', '2026-11-20T12:40:00Z', 'E', 90, '25-50', 25, 50, 6,
  1, 3, 2, 0, 'mixed', 38.5, -90.5);
select pg_temp.expect((select doe_count = 3 and fawn_count = 2 and deer_type = 'mixed'
  from deer_sightings where id = '77777777-7777-4777-8777-777777777777'), 'mixed group saved');
select pg_temp.expect_fail($$insert into deer_sightings (id, hunter_id, stand_id, session_id, observed_at,
  first_seen_direction, first_seen_bearing, distance_range, distance_min_yards, distance_max_yards,
  quantity, buck_count, doe_count, deer_type, stand_latitude, stand_longitude)
  values (gen_random_uuid(), public.current_hunter_id(), '11111111-1111-4111-8111-111111111111',
  '33333333-3333-4333-8333-333333333333', now(), 'E', 90, '25-50', 25, 50, 5, 1, 3, 'mixed', 38.5, -90.5)$$,
  'counts must add up to quantity');
select pg_temp.expect_fail($$insert into deer_sightings (id, hunter_id, stand_id, session_id, observed_at,
  first_seen_direction, first_seen_bearing, distance_range, distance_min_yards, distance_max_yards,
  quantity, fawn_count, deer_type, stand_latitude, stand_longitude)
  values (gen_random_uuid(), public.current_hunter_id(), '11111111-1111-4111-8111-111111111111',
  '33333333-3333-4333-8333-333333333333', now(), 'E', 90, '25-50', 25, 50, 2, 2, 'doe', 38.5, -90.5)$$,
  'deer_type must match counts');
select pg_temp.expect_fail($$update deer_sightings set doe_count = 4, quantity = 7
  where id = '77777777-7777-4777-8777-777777777777'$$, 'counts in an original sighting cannot be edited');
select pg_temp.expect_fail($$insert into gunshot_reports (id, hunter_id, stand_id, session_id, observed_at,
  direction, bearing, stand_latitude, stand_longitude)
  values (gen_random_uuid(), public.current_hunter_id(), '11111111-1111-4111-8111-111111111111',
  '33333333-3333-4333-8333-333333333333', now(), 'XX', 0, 38.5, -90.5)$$,
  'gunshot direction must be one of 16 points');

-- Impersonation: Mike's phone cannot write a record attributed to John
select pg_temp.expect_fail($$insert into hunting_sessions (id, hunter_id, stand_id, started_at)
  values (gen_random_uuid(), 'c0000000-0000-4000-8000-000000000003', '11111111-1111-4111-8111-111111111111', now())$$,
  'cannot create session for another hunter');

-- Original observation is immutable; voiding is allowed
select pg_temp.expect_fail($$update deer_sightings set quantity = 5 where id = '44444444-4444-4444-8444-444444444444'$$,
  'original sighting fields cannot be edited');
update gunshot_reports set status = 'voided', voided_at = now(), void_reason = 'Wrong direction'
  where id = '55555555-5555-4555-8555-555555555555';
select pg_temp.expect((select status from gunshot_reports where id = '55555555-5555-4555-8555-555555555555') = 'voided', 'hunter can void own report');
select pg_temp.expect_fail($$update gunshot_reports set status = 'active', voided_at = null where id = '55555555-5555-4555-8555-555555555555'$$,
  'voided report cannot be restored');

-- End the session
update hunting_sessions set ended_at = '2026-11-20T15:00:00Z' where id = '33333333-3333-4333-8333-333333333333';
select pg_temp.expect_fail($$update hunting_sessions set started_at = now() where id = '33333333-3333-4333-8333-333333333333'$$,
  'session start time cannot change');
reset role;

-- ---- John sees Mike's shared records but cannot void them or add to Mike's hunt
select pg_temp.act_as('00000000-0000-4000-8000-00000000000c');
select pg_temp.expect((select count(*) from deer_sightings) = 2, 'other hunter can read shared sightings');
select pg_temp.expect((select count(*) from profiles) = 3, 'member can see hunter names');
update deer_sightings set status = 'voided', voided_at = now() where id = '44444444-4444-4444-8444-444444444444';
select pg_temp.expect_fail($$insert into gunshot_reports (id, hunter_id, stand_id, session_id, observed_at,
  direction, bearing, stand_latitude, stand_longitude)
  values (gen_random_uuid(), public.current_hunter_id(), '11111111-1111-4111-8111-111111111111',
  '33333333-3333-4333-8333-333333333333', now(), 'N', 0, 38.5, -90.5)$$,
  'cannot attach report to another hunter''s session');
reset role;
select pg_temp.expect((select status from deer_sightings where id = '44444444-4444-4444-8444-444444444444') = 'active', 'cannot void another hunter''s sighting');

-- ---- Anonymous (no account at all) gets nothing
set role anon;
select pg_temp.expect_fail($$select count(*) from deer_sightings$$, 'anonymous access denied');
select pg_temp.expect_fail($$select public.camp_roster('482913')$$, 'anonymous cannot ask for the hunter list');
reset role;

-- ---- Admin: add, rename, release a name, change the code; cannot remove the last admin
select pg_temp.act_as('00000000-0000-4000-8000-00000000000a');
insert into profiles (display_name, is_active) values ('Dave', true);
select pg_temp.expect((select count(*) from profiles where display_name = 'Dave' and is_active) = 1, 'admin can add a hunter');
update profiles set display_name = 'Johnny' where id = 'c0000000-0000-4000-8000-000000000003';
select pg_temp.expect((select display_name from profiles where id = 'c0000000-0000-4000-8000-000000000003') = 'Johnny', 'admin can rename a hunter');
select pg_temp.expect((select count(*) from jsonb_array_elements(public.hunter_list()) h where (h ->> 'in_use')::boolean) = 3, 'admin sees which names are in use');
select public.release_hunter('b0000000-0000-4000-8000-000000000002');
select pg_temp.expect_fail($$update profiles set is_admin = false where id = 'a0000000-0000-4000-8000-000000000001'$$,
  'last admin cannot be removed');
select pg_temp.expect_fail($$update profiles set created_at = now() where id = 'b0000000-0000-4000-8000-000000000002'$$,
  'admin cannot edit protected profile columns');
select public.set_camp_code('777888');
reset role;

-- Mike's old phone no longer writes as Mike once released
select pg_temp.act_as('00000000-0000-4000-8000-00000000000b');
select pg_temp.expect(public.whoami() -> 'hunter' = 'null'::jsonb, 'released phone is signed out');
select pg_temp.expect_fail($$insert into hunting_sessions (id, hunter_id, stand_id, started_at)
  values (gen_random_uuid(), 'b0000000-0000-4000-8000-000000000002', '11111111-1111-4111-8111-111111111111', now())$$,
  'released phone cannot write');
select pg_temp.expect(public.join_camp('482913', 'b0000000-0000-4000-8000-000000000002') ->> 'error' = 'wrong', 'old camp code stops working after a change');
reset role;

-- The stranger's lock-out was cleared by the code change; Mike can be taken on a new phone
select pg_temp.act_as('00000000-0000-4000-8000-00000000000d');
select pg_temp.expect((public.join_camp('777888', 'b0000000-0000-4000-8000-000000000002') ->> 'ok')::boolean, 'released name can be used on a new phone');
select pg_temp.expect((select count(*) from deer_sightings where hunter_id = public.current_hunter_id()) = 2, 'new phone sees Mike''s earlier records');
-- "Switch hunter": leaving frees the name
select public.leave_camp();
select pg_temp.expect(public.whoami() -> 'hunter' = 'null'::jsonb, 'leave_camp signs this phone out');
reset role;

-- Deactivated hunters are signed out everywhere
select pg_temp.act_as('00000000-0000-4000-8000-00000000000a');
update profiles set is_active = false where id = 'c0000000-0000-4000-8000-000000000003';
reset role;
select pg_temp.act_as('00000000-0000-4000-8000-00000000000c');
select pg_temp.expect(public.whoami() -> 'hunter' = 'null'::jsonb, 'deactivated hunter is signed out');
select pg_temp.expect((select count(*) from deer_sightings) = 0, 'deactivated hunter sees nothing');
reset role;

-- No property concept anywhere
select pg_temp.expect((select count(*) from information_schema.columns
  where table_schema = 'public' and column_name ilike '%propert%') = 0, 'no property columns exist');
select pg_temp.expect((select count(*) from information_schema.tables
  where table_schema = 'public' and table_name ilike '%propert%') = 0, 'no property tables exist');

\echo ALL DATABASE TESTS PASSED
