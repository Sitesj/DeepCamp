-- A sighting recorded with the version-1 schema (applied between migrations 1 and 2)
\set ON_ERROR_STOP on
insert into auth.users (id, email) values ('00000000-0000-4000-8000-0000000000f1', 'legacy@camp.test');
update public.profiles set is_active = true where id = '00000000-0000-4000-8000-0000000000f1';
insert into public.stands (id, name, latitude, longitude) values ('99999999-9999-4999-8999-999999999999', 'Old Stand', 38.5, -90.5);
insert into public.hunting_sessions (id, hunter_id, stand_id, started_at)
  values ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', '00000000-0000-4000-8000-0000000000f1', '99999999-9999-4999-8999-999999999999', '2026-11-01T12:00:00Z');
insert into public.deer_sightings (id, hunter_id, stand_id, session_id, observed_at, first_seen_direction,
  first_seen_bearing, distance_range, distance_min_yards, distance_max_yards, quantity, deer_type, stand_latitude, stand_longitude)
values ('88888888-8888-4888-8888-888888888888', '00000000-0000-4000-8000-0000000000f1', '99999999-9999-4999-8999-999999999999',
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', '2026-11-01T12:30:00Z', 'N', 0, '0-25', 0, 25, 2, 'doe', 38.5, -90.5);
