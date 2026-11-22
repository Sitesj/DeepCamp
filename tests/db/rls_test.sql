-- Deer Camp database tests: constraints, triggers and Row Level Security.
-- Run with: tests/db/run.sh   (each failed expectation raises an exception)
\set ON_ERROR_STOP on
set client_min_messages = notice;

-- Fixture users (as the database owner, like the Supabase dashboard would)
insert into public.hunter_invites (email, display_name, is_admin) values
  ('admin@camp.test', 'Admin Al', true),
  ('mike@camp.test',  'Mike', false),
  ('john@camp.test',  'John', false);
insert into auth.users (id, email) values
  ('00000000-0000-4000-8000-00000000000a', 'Admin@Camp.test'),
  ('00000000-0000-4000-8000-00000000000b', 'mike@camp.test'),
  ('00000000-0000-4000-8000-00000000000c', 'john@camp.test'),
  ('00000000-0000-4000-8000-00000000000d', 'stranger@else.test');

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

-- Profiles created by trigger
select pg_temp.expect((select count(*) from profiles where is_active) = 3, 'invited users are active');
select pg_temp.expect((select is_admin from profiles where id = '00000000-0000-4000-8000-00000000000a'), 'admin flag from invite (case-insensitive email)');
select pg_temp.expect((select not is_active from profiles where id = '00000000-0000-4000-8000-00000000000d'), 'uninvited user is inactive');

-- ---- Admin creates stands
select pg_temp.act_as('00000000-0000-4000-8000-00000000000a');
insert into stands (id, name, latitude, longitude) values
  ('11111111-1111-4111-8111-111111111111', 'North Ridge', 38.5000, -90.5000),
  ('22222222-2222-4222-8222-222222222222', 'Creek Stand', 38.5050, -90.4900);
reset role;

-- ---- Hunter cannot manage stands
select pg_temp.act_as('00000000-0000-4000-8000-00000000000b');
select pg_temp.expect_fail($$insert into stands (name, latitude, longitude) values ('Sneaky', 1, 1)$$, 'hunter cannot add stand');
update stands set name = 'Renamed' where id = '11111111-1111-4111-8111-111111111111';
select pg_temp.expect((select name from stands where id = '11111111-1111-4111-8111-111111111111') = 'North Ridge', 'hunter update of stand has no effect');
update profiles set is_admin = true where id = auth.uid();
select pg_temp.expect((select not is_admin from profiles where id = auth.uid()), 'hunter cannot promote self');
reset role;

-- ---- Mike records a session, a sighting and a gunshot (as the app does: upsert)
select pg_temp.act_as('00000000-0000-4000-8000-00000000000b');
insert into hunting_sessions (id, hunter_id, stand_id, started_at, stand_latitude, stand_longitude)
values ('33333333-3333-4333-8333-333333333333', '00000000-0000-4000-8000-00000000000b',
        '11111111-1111-4111-8111-111111111111', '2026-11-20T11:00:00Z', 38.5, -90.5);

insert into deer_sightings (id, hunter_id, stand_id, session_id, observed_at, first_seen_direction,
  first_seen_bearing, distance_range, distance_min_yards, distance_max_yards, heading_direction,
  heading_bearing, quantity, deer_type, stand_latitude, stand_longitude, est_latitude, est_longitude, status)
values ('44444444-4444-4444-8444-444444444444', '00000000-0000-4000-8000-00000000000b',
  '11111111-1111-4111-8111-111111111111', '33333333-3333-4333-8333-333333333333',
  '2026-11-20T12:12:00Z', 'NE', 45, '50-75', 50, 75, 'SW', 225, 2, 'doe', 38.5, -90.5, 38.5004, -90.4995, 'active');

-- Idempotent re-upload of the identical record (same UUID) must not duplicate or fail
insert into deer_sightings (id, hunter_id, stand_id, session_id, observed_at, first_seen_direction,
  first_seen_bearing, distance_range, distance_min_yards, distance_max_yards, heading_direction,
  heading_bearing, quantity, deer_type, stand_latitude, stand_longitude, est_latitude, est_longitude, status)
values ('44444444-4444-4444-8444-444444444444', '00000000-0000-4000-8000-00000000000b',
  '11111111-1111-4111-8111-111111111111', '33333333-3333-4333-8333-333333333333',
  '2026-11-20T12:12:00Z', 'NE', 45, '50-75', 50, 75, 'SW', 225, 2, 'doe', 38.5, -90.5, 38.5004, -90.4995, 'active')
on conflict (id) do update set
  hunter_id = excluded.hunter_id, stand_id = excluded.stand_id, session_id = excluded.session_id,
  observed_at = excluded.observed_at, first_seen_direction = excluded.first_seen_direction,
  first_seen_bearing = excluded.first_seen_bearing, distance_range = excluded.distance_range,
  quantity = excluded.quantity, deer_type = excluded.deer_type, status = excluded.status;
select pg_temp.expect((select count(*) from deer_sightings) = 1, 'duplicate upload is idempotent');

insert into gunshot_reports (id, hunter_id, stand_id, session_id, observed_at, direction, bearing,
  stand_latitude, stand_longitude)
values ('55555555-5555-4555-8555-555555555555', '00000000-0000-4000-8000-00000000000b',
  '11111111-1111-4111-8111-111111111111', '33333333-3333-4333-8333-333333333333',
  '2026-11-20T12:28:00Z', 'NW', 315, 38.5, -90.5);

-- Bad data rejected by constraints
select pg_temp.expect_fail($$insert into deer_sightings (id, hunter_id, stand_id, session_id, observed_at,
  first_seen_direction, first_seen_bearing, distance_range, distance_min_yards, distance_max_yards,
  quantity, deer_type, stand_latitude, stand_longitude)
  values (gen_random_uuid(), auth.uid(), '11111111-1111-4111-8111-111111111111',
  '33333333-3333-4333-8333-333333333333', now(), 'NE', 90, '50-75', 50, 75, 1, 'doe', 38.5, -90.5)$$,
  'bearing must match direction');
select pg_temp.expect_fail($$insert into deer_sightings (id, hunter_id, stand_id, session_id, observed_at,
  first_seen_direction, first_seen_bearing, distance_range, distance_min_yards, distance_max_yards,
  quantity, deer_type, stand_latitude, stand_longitude)
  values (gen_random_uuid(), auth.uid(), '11111111-1111-4111-8111-111111111111',
  '33333333-3333-4333-8333-333333333333', now(), 'NE', 45, '50-75', 50, 75, 0, 'doe', 38.5, -90.5)$$,
  'quantity must be at least 1');
select pg_temp.expect_fail($$insert into gunshot_reports (id, hunter_id, stand_id, session_id, observed_at,
  direction, bearing, stand_latitude, stand_longitude)
  values (gen_random_uuid(), auth.uid(), '11111111-1111-4111-8111-111111111111',
  '33333333-3333-4333-8333-333333333333', now(), 'XX', 0, 38.5, -90.5)$$,
  'gunshot direction must be one of 16 points');

-- Impersonation: Mike cannot write a record attributed to John
select pg_temp.expect_fail($$insert into hunting_sessions (id, hunter_id, stand_id, started_at)
  values (gen_random_uuid(), '00000000-0000-4000-8000-00000000000c', '11111111-1111-4111-8111-111111111111', now())$$,
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

-- ---- John sees Mike's shared records but cannot void them
select pg_temp.act_as('00000000-0000-4000-8000-00000000000c');
select pg_temp.expect((select count(*) from deer_sightings) = 1, 'other hunter can read shared sightings');
select pg_temp.expect((select count(*) from profiles) = 4, 'member can see group profiles');
update deer_sightings set status = 'voided', voided_at = now() where id = '44444444-4444-4444-8444-444444444444';
reset role;
select pg_temp.expect((select status from deer_sightings where id = '44444444-4444-4444-8444-444444444444') = 'active', 'cannot void another hunter''s sighting');

-- John cannot add a sighting into Mike's session
select pg_temp.act_as('00000000-0000-4000-8000-00000000000c');
select pg_temp.expect_fail($$insert into gunshot_reports (id, hunter_id, stand_id, session_id, observed_at,
  direction, bearing, stand_latitude, stand_longitude)
  values (gen_random_uuid(), auth.uid(), '11111111-1111-4111-8111-111111111111',
  '33333333-3333-4333-8333-333333333333', now(), 'N', 0, 38.5, -90.5)$$,
  'cannot attach report to another hunter''s session');
reset role;

-- ---- Uninvited (inactive) account sees nothing and cannot write
select pg_temp.act_as('00000000-0000-4000-8000-00000000000d');
select pg_temp.expect((select count(*) from deer_sightings) = 0, 'inactive account cannot read sightings');
select pg_temp.expect((select count(*) from stands) = 0, 'inactive account cannot read stands');
select pg_temp.expect((select count(*) from profiles) = 1, 'inactive account sees only own profile');
select pg_temp.expect_fail($$insert into hunting_sessions (id, hunter_id, stand_id, started_at)
  values (gen_random_uuid(), auth.uid(), '11111111-1111-4111-8111-111111111111', now())$$,
  'inactive account cannot create sessions');
reset role;

-- ---- Anonymous (not signed in) gets nothing
set role anon;
select pg_temp.expect_fail($$select count(*) from deer_sightings$$, 'anonymous access denied');
reset role;

-- ---- Admin activates the stranger and renames them; cannot remove the last admin
select pg_temp.act_as('00000000-0000-4000-8000-00000000000a');
update profiles set is_active = true, display_name = 'Dave' where id = '00000000-0000-4000-8000-00000000000d';
select pg_temp.expect((select is_active from profiles where id = '00000000-0000-4000-8000-00000000000d'), 'admin can activate hunter');
select pg_temp.expect_fail($$update profiles set is_admin = false where id = '00000000-0000-4000-8000-00000000000a'$$,
  'last admin cannot be removed');
select pg_temp.expect_fail($$update profiles set created_at = now() where id = '00000000-0000-4000-8000-00000000000d'$$,
  'admin cannot edit protected profile columns');
reset role;

-- ---- Inviting an e-mail that already signed up activates that account
insert into auth.users (id, email) values ('00000000-0000-4000-8000-00000000000e', 'late@camp.test');
select pg_temp.expect((select not is_active from profiles where id = '00000000-0000-4000-8000-00000000000e'), 'early sign-up starts inactive');
select pg_temp.act_as('00000000-0000-4000-8000-00000000000a');
insert into hunter_invites (email, display_name) values ('late@camp.test', 'Late Larry');
reset role;
select pg_temp.expect((select is_active and display_name = 'Late Larry' from profiles where id = '00000000-0000-4000-8000-00000000000e'), 'invite activates existing account');
select pg_temp.act_as('00000000-0000-4000-8000-00000000000b');
select pg_temp.expect_fail($$insert into hunter_invites (email, display_name) values ('x@y.test', 'X')$$, 'hunter cannot invite');
reset role;

-- No property concept anywhere
select pg_temp.expect((select count(*) from information_schema.columns
  where table_schema = 'public' and column_name ilike '%propert%') = 0, 'no property columns exist');
select pg_temp.expect((select count(*) from information_schema.tables
  where table_schema = 'public' and table_name ilike '%propert%') = 0, 'no property tables exist');

\echo ALL DATABASE TESTS PASSED
