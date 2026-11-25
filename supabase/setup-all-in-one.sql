-- Deer Camp: complete database setup for a NEW Supabase project.
-- This is all the files in supabase/migrations/ joined together.
-- Paste it all into SQL Editor -> New query -> Run.
-- Regenerate with: bash tests/db/build_all_in_one.sh

-- ===== 20261122000001_deer_camp_schema.sql =====
-- Deer Camp — initial schema (version 1)
--
-- One private hunting group. Hunters are Supabase Auth users with a row in
-- public.profiles. Only ACTIVE profiles can see or write shared data.
-- There is intentionally no property table and no property_id anywhere.

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------------
-- Helper: compass direction -> bearing (degrees). 16 points, N = 0, 22.5° steps.
-- ---------------------------------------------------------------------------
create or replace function public.compass_bearing(dir text)
returns numeric
language sql
immutable
as $$
  select (array_position(
    array['N','NNE','NE','ENE','E','ESE','SE','SSE','S','SSW','SW','WSW','W','WNW','NW','NNW'],
    dir) - 1) * 22.5
$$;

-- ---------------------------------------------------------------------------
-- Profiles (one per Supabase Auth user)
-- ---------------------------------------------------------------------------
create table public.profiles (
  id            uuid primary key references auth.users (id) on delete cascade,
  display_name  text not null check (char_length(btrim(display_name)) between 1 and 60),
  is_admin      boolean not null default false,
  is_active     boolean not null default false,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

-- Hunters an administrator has added by e-mail. When that person creates an
-- account (or the admin creates it in the Supabase dashboard) the profile is
-- activated automatically with this display name.
create table public.hunter_invites (
  email         text primary key check (email = lower(btrim(email)) and position('@' in email) > 1),
  display_name  text not null check (char_length(btrim(display_name)) between 1 and 60),
  is_admin      boolean not null default false,
  created_by    uuid references public.profiles (id) on delete set null,
  created_at    timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Stands
-- ---------------------------------------------------------------------------
create table public.stands (
  id           uuid primary key default gen_random_uuid(),
  name         text not null check (char_length(btrim(name)) between 1 and 60),
  latitude     double precision not null check (latitude between -90 and 90),
  longitude    double precision not null check (longitude between -180 and 180),
  description  text check (description is null or char_length(description) <= 500),
  is_active    boolean not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create unique index stands_name_active_uq on public.stands (lower(name)) where is_active;

-- ---------------------------------------------------------------------------
-- Hunting sessions
-- ---------------------------------------------------------------------------
create table public.hunting_sessions (
  id               uuid primary key,                 -- generated on the phone
  hunter_id        uuid not null default auth.uid() references public.profiles (id),
  stand_id         uuid not null references public.stands (id),
  started_at       timestamptz not null,
  ended_at         timestamptz,
  stand_latitude   double precision check (stand_latitude between -90 and 90),
  stand_longitude  double precision check (stand_longitude between -180 and 180),
  server_received_at timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  constraint hunting_sessions_end_after_start check (ended_at is null or ended_at >= started_at)
);
create index hunting_sessions_started_idx on public.hunting_sessions (started_at);
create index hunting_sessions_hunter_idx on public.hunting_sessions (hunter_id);
create index hunting_sessions_stand_idx on public.hunting_sessions (stand_id);
create index hunting_sessions_updated_idx on public.hunting_sessions (updated_at);

-- ---------------------------------------------------------------------------
-- Deer sightings
-- ---------------------------------------------------------------------------
create table public.deer_sightings (
  id                    uuid primary key,             -- generated on the phone
  hunter_id             uuid not null default auth.uid() references public.profiles (id),
  stand_id              uuid not null references public.stands (id),
  session_id            uuid not null references public.hunting_sessions (id),
  observed_at           timestamptz not null,         -- when the hunter began reporting
  first_seen_direction  text not null,
  first_seen_bearing    numeric(5,1) not null,
  distance_range        text not null,
  distance_min_yards    numeric not null,
  distance_max_yards    numeric not null,
  heading_direction     text,                         -- null = NOT SURE
  heading_bearing       numeric(5,1),
  quantity              integer not null check (quantity between 1 and 500),
  deer_type             text not null check (deer_type in ('buck','doe','unknown')),
  stand_latitude        double precision not null check (stand_latitude between -90 and 90),
  stand_longitude       double precision not null check (stand_longitude between -180 and 180),
  est_latitude          double precision check (est_latitude between -90 and 90),   -- derived, approximate
  est_longitude         double precision check (est_longitude between -180 and 180),-- derived, approximate
  weather               jsonb,
  status                text not null default 'active' check (status in ('active','voided')),
  voided_at             timestamptz,
  void_reason           text check (void_reason is null or char_length(void_reason) <= 200),
  corrects_id           uuid references public.deer_sightings (id),
  recorded_at           timestamptz,                  -- when saved on the phone
  server_received_at    timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  constraint deer_first_seen_ok check (
    public.compass_bearing(first_seen_direction) is not null
    and first_seen_bearing = public.compass_bearing(first_seen_direction)),
  constraint deer_heading_ok check (
    (heading_direction is null and heading_bearing is null)
    or (public.compass_bearing(heading_direction) is not null
        and heading_bearing = public.compass_bearing(heading_direction))),
  constraint deer_distance_ok check (
    (distance_range, distance_min_yards, distance_max_yards) in
      (('0-25',0,25),('25-50',25,50),('50-75',50,75),('75-100',75,100),('100-200',100,200))),
  constraint deer_void_ok check ((status = 'voided') = (voided_at is not null))
);
create index deer_sightings_observed_idx on public.deer_sightings (observed_at);
create index deer_sightings_stand_idx on public.deer_sightings (stand_id);
create index deer_sightings_hunter_idx on public.deer_sightings (hunter_id);
create index deer_sightings_session_idx on public.deer_sightings (session_id);
create index deer_sightings_updated_idx on public.deer_sightings (updated_at);

-- ---------------------------------------------------------------------------
-- Gunshot reports
-- ---------------------------------------------------------------------------
create table public.gunshot_reports (
  id                  uuid primary key,               -- generated on the phone
  hunter_id           uuid not null default auth.uid() references public.profiles (id),
  stand_id            uuid not null references public.stands (id),
  session_id          uuid not null references public.hunting_sessions (id),
  observed_at         timestamptz not null,           -- when GUNSHOT HEARD was tapped
  direction           text not null,
  bearing             numeric(5,1) not null,
  stand_latitude      double precision not null check (stand_latitude between -90 and 90),
  stand_longitude     double precision not null check (stand_longitude between -180 and 180),
  weather             jsonb,
  status              text not null default 'active' check (status in ('active','voided')),
  voided_at           timestamptz,
  void_reason         text check (void_reason is null or char_length(void_reason) <= 200),
  corrects_id         uuid references public.gunshot_reports (id),
  recorded_at         timestamptz,
  server_received_at  timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  constraint gunshot_direction_ok check (
    public.compass_bearing(direction) is not null and bearing = public.compass_bearing(direction)),
  constraint gunshot_void_ok check ((status = 'voided') = (voided_at is not null))
);
create index gunshot_reports_observed_idx on public.gunshot_reports (observed_at);
create index gunshot_reports_stand_idx on public.gunshot_reports (stand_id);
create index gunshot_reports_hunter_idx on public.gunshot_reports (hunter_id);
create index gunshot_reports_session_idx on public.gunshot_reports (session_id);
create index gunshot_reports_updated_idx on public.gunshot_reports (updated_at);

-- ---------------------------------------------------------------------------
-- Triggers
-- ---------------------------------------------------------------------------
create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

create trigger profiles_touch before update on public.profiles
  for each row execute function public.touch_updated_at();
create trigger stands_touch before update on public.stands
  for each row execute function public.touch_updated_at();
create trigger sessions_touch before insert or update on public.hunting_sessions
  for each row execute function public.touch_updated_at();
create trigger sightings_touch before insert or update on public.deer_sightings
  for each row execute function public.touch_updated_at();
create trigger gunshots_touch before insert or update on public.gunshot_reports
  for each row execute function public.touch_updated_at();

-- Server-managed columns can never be set or changed by a client.
create or replace function public.protect_server_columns()
returns trigger language plpgsql as $$
begin
  if tg_op = 'INSERT' then
    new.server_received_at := now();
  else
    new.server_received_at := old.server_received_at;
  end if;
  return new;
end $$;

create trigger sessions_server_cols before insert or update on public.hunting_sessions
  for each row execute function public.protect_server_columns();
create trigger sightings_server_cols before insert or update on public.deer_sightings
  for each row execute function public.protect_server_columns();
create trigger gunshots_server_cols before insert or update on public.gunshot_reports
  for each row execute function public.protect_server_columns();

-- Sessions: only ended_at may change after creation.
create or replace function public.guard_session_update()
returns trigger language plpgsql as $$
begin
  if new.hunter_id is distinct from old.hunter_id
     or new.stand_id is distinct from old.stand_id
     or new.started_at is distinct from old.started_at then
    raise exception 'Hunting session % cannot be reassigned or re-timed', old.id
      using errcode = 'check_violation';
  end if;
  return new;
end $$;
create trigger sessions_guard before update on public.hunting_sessions
  for each row execute function public.guard_session_update();

-- Observations are an audit trail: the original report never changes.
-- The only allowed change is voiding it (active -> voided) with a reason.
create or replace function public.guard_observation_update()
returns trigger language plpgsql as $$
declare
  old_core jsonb;
  new_core jsonb;
begin
  old_core := to_jsonb(old) - array['status','voided_at','void_reason','updated_at','server_received_at'];
  new_core := to_jsonb(new) - array['status','voided_at','void_reason','updated_at','server_received_at'];
  if old_core is distinct from new_core then
    raise exception 'Original observation % cannot be changed; void it and record a correction instead', old.id
      using errcode = 'check_violation';
  end if;
  if old.status = 'voided' and new.status = 'active' then
    raise exception 'Voided observation % cannot be restored', old.id using errcode = 'check_violation';
  end if;
  if old.status = 'voided' then
    -- keep the original void details
    new.voided_at := old.voided_at;
    new.void_reason := old.void_reason;
  end if;
  return new;
end $$;
create trigger sightings_guard before update on public.deer_sightings
  for each row execute function public.guard_observation_update();
create trigger gunshots_guard before update on public.gunshot_reports
  for each row execute function public.guard_observation_update();

-- New Supabase Auth user -> profile. Invited e-mails are activated with the
-- invite's display name; anyone else gets an INACTIVE profile with no access
-- until an administrator activates it.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  inv public.hunter_invites%rowtype;
begin
  select * into inv from public.hunter_invites where email = lower(new.email);
  if found then
    insert into public.profiles (id, display_name, is_admin, is_active)
    values (new.id, inv.display_name, inv.is_admin, true)
    on conflict (id) do nothing;
  else
    insert into public.profiles (id, display_name, is_admin, is_active)
    values (new.id,
            left(coalesce(nullif(btrim(new.raw_user_meta_data ->> 'display_name'), ''),
                          split_part(coalesce(new.email, 'hunter'), '@', 1)), 60),
            false, false)
    on conflict (id) do nothing;
  end if;
  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Adding an invite for an e-mail that already has an account activates it.
create or replace function public.apply_invite_to_existing_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.profiles p
     set is_active = true,
         display_name = new.display_name,
         is_admin = p.is_admin or new.is_admin
    from auth.users u
   where u.id = p.id and lower(u.email) = new.email;
  return new;
end $$;

create trigger hunter_invites_apply
  after insert or update on public.hunter_invites
  for each row execute function public.apply_invite_to_existing_user();

-- Admins cannot accidentally lock everyone out by removing the last admin.
create or replace function public.guard_last_admin()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if (old.is_admin and old.is_active) and not (new.is_admin and new.is_active) then
    if not exists (select 1 from public.profiles
                   where is_admin and is_active and id <> old.id) then
      raise exception 'At least one active administrator is required' using errcode = 'check_violation';
    end if;
  end if;
  return new;
end $$;
create trigger profiles_last_admin before update on public.profiles
  for each row execute function public.guard_last_admin();

-- ---------------------------------------------------------------------------
-- Membership helpers (security definer so policies can read profiles safely)
-- ---------------------------------------------------------------------------
create or replace function public.is_active_member()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and is_active);
$$;

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and is_active and is_admin);
$$;

-- ---------------------------------------------------------------------------
-- Row Level Security
-- ---------------------------------------------------------------------------
alter table public.profiles         enable row level security;
alter table public.hunter_invites   enable row level security;
alter table public.stands           enable row level security;
alter table public.hunting_sessions enable row level security;
alter table public.deer_sightings   enable row level security;
alter table public.gunshot_reports  enable row level security;

-- Profiles: members see the group; everyone can see their own (pending) row.
create policy profiles_select on public.profiles for select to authenticated
  using (id = auth.uid() or public.is_active_member());
create policy profiles_admin_update on public.profiles for update to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- Invites: administrators only.
create policy invites_admin_all on public.hunter_invites for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- Stands: members read, administrators write. No deletes (deactivate instead).
create policy stands_select on public.stands for select to authenticated
  using (public.is_active_member());
create policy stands_admin_insert on public.stands for insert to authenticated
  with check (public.is_admin());
create policy stands_admin_update on public.stands for update to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- Sessions: members read all; hunters create/update only their own.
create policy sessions_select on public.hunting_sessions for select to authenticated
  using (public.is_active_member());
create policy sessions_insert_own on public.hunting_sessions for insert to authenticated
  with check (public.is_active_member() and hunter_id = auth.uid());
create policy sessions_update_own on public.hunting_sessions for update to authenticated
  using (hunter_id = auth.uid() and public.is_active_member())
  with check (hunter_id = auth.uid());

-- Sightings: members read all; hunters create their own inside their own
-- session; hunters may void their own.
create policy sightings_select on public.deer_sightings for select to authenticated
  using (public.is_active_member());
create policy sightings_insert_own on public.deer_sightings for insert to authenticated
  with check (
    public.is_active_member() and hunter_id = auth.uid()
    and exists (select 1 from public.hunting_sessions s
                where s.id = session_id and s.hunter_id = auth.uid()));
create policy sightings_update_own on public.deer_sightings for update to authenticated
  using (hunter_id = auth.uid() and public.is_active_member())
  with check (hunter_id = auth.uid());

create policy gunshots_select on public.gunshot_reports for select to authenticated
  using (public.is_active_member());
create policy gunshots_insert_own on public.gunshot_reports for insert to authenticated
  with check (
    public.is_active_member() and hunter_id = auth.uid()
    and exists (select 1 from public.hunting_sessions s
                where s.id = session_id and s.hunter_id = auth.uid()));
create policy gunshots_update_own on public.gunshot_reports for update to authenticated
  using (hunter_id = auth.uid() and public.is_active_member())
  with check (hunter_id = auth.uid());

-- Column-level protection: admins may edit profile name/flags, nothing else.
revoke all on public.profiles, public.hunter_invites, public.stands,
  public.hunting_sessions, public.deer_sightings, public.gunshot_reports from anon;
revoke all on public.profiles from authenticated;
grant select on public.profiles to authenticated;
grant update (display_name, is_admin, is_active) on public.profiles to authenticated;
grant select, insert, update, delete on public.hunter_invites to authenticated;
grant select, insert, update on public.stands to authenticated;
grant select, insert, update on public.hunting_sessions to authenticated;
grant select, insert, update on public.deer_sightings to authenticated;
grant select, insert, update on public.gunshot_reports to authenticated;
grant execute on function public.is_active_member(), public.is_admin(), public.compass_bearing(text) to authenticated;

-- ---------------------------------------------------------------------------
-- Realtime (optional; skipped when the publication does not exist)
-- ---------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table
      public.stands, public.hunting_sessions, public.deer_sightings, public.gunshot_reports;
  end if;
end $$;

-- ===== 20261122000002_mixed_deer_groups.sql =====
-- Deer Camp — mixed deer groups (version 2)
--
-- One sighting can now hold a group of different deer, e.g. 3 does, 1 buck
-- and 2 fawns. Each sighting stores a count per type; `quantity` is the
-- total and `deer_type` is the single type seen, or 'mixed'.
-- Run this AFTER 20261122000001_deer_camp_schema.sql. Safe to run more than once.

alter table public.deer_sightings
  add column if not exists buck_count    integer not null default 0 check (buck_count between 0 and 500),
  add column if not exists doe_count     integer not null default 0 check (doe_count between 0 and 500),
  add column if not exists fawn_count    integer not null default 0 check (fawn_count between 0 and 500),
  add column if not exists unknown_count integer not null default 0 check (unknown_count between 0 and 500);

-- Existing single-type sightings: put their quantity under their type.
-- (The audit trigger blocks edits to original observations, so it is paused
-- for this one-time conversion.)
alter table public.deer_sightings disable trigger sightings_guard;
update public.deer_sightings set
  buck_count    = case when deer_type = 'buck'    then quantity else 0 end,
  doe_count     = case when deer_type = 'doe'     then quantity else 0 end,
  unknown_count = case when deer_type = 'unknown' then quantity else 0 end
where buck_count + doe_count + fawn_count + unknown_count = 0;   -- only rows not yet converted
alter table public.deer_sightings enable trigger sightings_guard;

alter table public.deer_sightings drop constraint if exists deer_sightings_deer_type_check;
alter table public.deer_sightings drop constraint if exists deer_counts_total_ok;
alter table public.deer_sightings drop constraint if exists deer_type_matches_counts;

alter table public.deer_sightings
  add constraint deer_counts_total_ok check (
    buck_count + doe_count + fawn_count + unknown_count = quantity),
  add constraint deer_type_matches_counts check (
    deer_type = case
      when (buck_count > 0)::int + (doe_count > 0)::int + (fawn_count > 0)::int + (unknown_count > 0)::int > 1 then 'mixed'
      when buck_count > 0 then 'buck'
      when doe_count > 0 then 'doe'
      when fawn_count > 0 then 'fawn'
      else 'unknown'
    end);

-- ===== 20261125000003_camp_code_sign_in.sql =====
-- Deer Camp — camp code sign-in (version 3)
--
-- Hunters no longer need an e-mail address. Each phone signs in to Supabase
-- anonymously (a private, persistent account for that phone), then joins the
-- camp by entering the shared CAMP CODE and tapping their name.
--
--  * A hunter name can be linked to ONE phone at a time. While Mike's phone
--    holds "Mike", nobody else can pick Mike, even with the camp code.
--    An administrator can release a name (lost or new phone).
--  * Records are owned by the hunter, not the phone: hunter_id must equal the
--    hunter linked to the signed-in phone (enforced below).
--  * The camp code is stored only as a bcrypt hash and is checked on the
--    server, with a lock-out after 5 wrong tries (15 minutes).
--
-- Run this AFTER migrations 1 and 2. Safe to run more than once.
-- Supabase: Authentication → Sign In / Providers → turn ON "Allow anonymous sign-ins".

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------
create table if not exists public.camp_settings (
  id          integer primary key default 1 check (id = 1),
  code_hash   text,
  updated_at  timestamptz not null default now()
);
insert into public.camp_settings (id) values (1) on conflict do nothing;

-- Which hunter each phone (Supabase auth user) is signed in as.
create table if not exists public.hunter_devices (
  user_id       uuid primary key references auth.users (id) on delete cascade,
  hunter_id     uuid not null references public.profiles (id) on delete cascade,
  linked_at     timestamptz not null default now(),
  last_seen_at  timestamptz not null default now()
);
create unique index if not exists hunter_devices_one_phone_per_hunter on public.hunter_devices (hunter_id);

-- Wrong camp-code attempts per phone (lock-out after 5 within 15 minutes).
create table if not exists public.join_attempts (
  user_id          uuid primary key references auth.users (id) on delete cascade,
  failures         integer not null default 0,
  last_failure_at  timestamptz not null default now()
);

alter table public.camp_settings  enable row level security;  -- no policies: only the functions below
alter table public.hunter_devices enable row level security;
alter table public.join_attempts  enable row level security;
revoke all on public.camp_settings, public.hunter_devices, public.join_attempts from anon, authenticated;

-- ---------------------------------------------------------------------------
-- Hunters are no longer tied 1:1 to auth accounts
-- ---------------------------------------------------------------------------
alter table public.profiles drop constraint if exists profiles_id_fkey;
alter table public.profiles alter column id set default gen_random_uuid();

-- Accounts created with the e-mail sign-in keep working: link them as phones.
insert into public.hunter_devices (user_id, hunter_id)
select p.id, p.id from public.profiles p join auth.users u on u.id = p.id
on conflict do nothing;

-- E-mail invites and automatic profiles for new accounts are no longer used.
drop trigger if exists on_auth_user_created on auth.users;
drop function if exists public.handle_new_user();
drop table if exists public.hunter_invites cascade;
drop function if exists public.apply_invite_to_existing_user();

-- ---------------------------------------------------------------------------
-- Who is signed in on this phone
-- ---------------------------------------------------------------------------
create or replace function public.current_hunter_id()
returns uuid language sql stable security definer set search_path = public as $$
  select d.hunter_id
    from public.hunter_devices d
    join public.profiles p on p.id = d.hunter_id
   where d.user_id = auth.uid() and p.is_active;
$$;

create or replace function public.is_active_member()
returns boolean language sql stable security definer set search_path = public as $$
  select public.current_hunter_id() is not null;
$$;

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = public.current_hunter_id() and is_admin);
$$;

alter table public.hunting_sessions alter column hunter_id set default public.current_hunter_id();
alter table public.deer_sightings   alter column hunter_id set default public.current_hunter_id();
alter table public.gunshot_reports  alter column hunter_id set default public.current_hunter_id();

-- ---------------------------------------------------------------------------
-- Policies: ownership is by hunter (via the phone's link), not by auth id
-- ---------------------------------------------------------------------------
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select to authenticated
  using (public.is_active_member());
drop policy if exists profiles_admin_insert on public.profiles;
create policy profiles_admin_insert on public.profiles for insert to authenticated
  with check (public.is_admin());

drop policy if exists sessions_insert_own on public.hunting_sessions;
drop policy if exists sessions_update_own on public.hunting_sessions;
create policy sessions_insert_own on public.hunting_sessions for insert to authenticated
  with check (public.is_active_member() and hunter_id = public.current_hunter_id());
create policy sessions_update_own on public.hunting_sessions for update to authenticated
  using (hunter_id = public.current_hunter_id())
  with check (hunter_id = public.current_hunter_id());

drop policy if exists sightings_insert_own on public.deer_sightings;
drop policy if exists sightings_update_own on public.deer_sightings;
create policy sightings_insert_own on public.deer_sightings for insert to authenticated
  with check (
    public.is_active_member() and hunter_id = public.current_hunter_id()
    and exists (select 1 from public.hunting_sessions s
                where s.id = session_id and s.hunter_id = public.current_hunter_id()));
create policy sightings_update_own on public.deer_sightings for update to authenticated
  using (hunter_id = public.current_hunter_id())
  with check (hunter_id = public.current_hunter_id());

drop policy if exists gunshots_insert_own on public.gunshot_reports;
drop policy if exists gunshots_update_own on public.gunshot_reports;
create policy gunshots_insert_own on public.gunshot_reports for insert to authenticated
  with check (
    public.is_active_member() and hunter_id = public.current_hunter_id()
    and exists (select 1 from public.hunting_sessions s
                where s.id = session_id and s.hunter_id = public.current_hunter_id()));
create policy gunshots_update_own on public.gunshot_reports for update to authenticated
  using (hunter_id = public.current_hunter_id())
  with check (hunter_id = public.current_hunter_id());

grant insert (display_name, is_admin, is_active) on public.profiles to authenticated;

-- ---------------------------------------------------------------------------
-- Camp code functions (called by the app through the API)
-- ---------------------------------------------------------------------------
-- Internal: 'ok' | 'wrong' | 'locked' | 'not_set' | 'not_signed_in'
create or replace function public.check_camp_code(code text)
returns text language plpgsql security definer set search_path = public, extensions as $$
declare
  h   text;
  a   public.join_attempts%rowtype;
  uid uuid := auth.uid();
begin
  if uid is null then return 'not_signed_in'; end if;
  select code_hash into h from public.camp_settings where id = 1;
  if h is null then return 'not_set'; end if;
  select * into a from public.join_attempts where user_id = uid;
  if found and a.failures >= 5 and a.last_failure_at > now() - interval '15 minutes' then
    return 'locked';
  end if;
  if crypt(coalesce(btrim(code), ''), h) = h then
    delete from public.join_attempts where user_id = uid;
    return 'ok';
  end if;
  insert into public.join_attempts (user_id, failures, last_failure_at) values (uid, 1, now())
  on conflict (user_id) do update set
    failures = case when public.join_attempts.last_failure_at < now() - interval '15 minutes'
                    then 1 else public.join_attempts.failures + 1 end,
    last_failure_at = now();
  return 'wrong';
end $$;

-- The list of hunter names, only for someone who knows the camp code.
create or replace function public.camp_roster(code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r text := public.check_camp_code(code);
begin
  if r <> 'ok' then return jsonb_build_object('ok', false, 'error', r); end if;
  return jsonb_build_object('ok', true, 'hunters', coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', p.id,
             'display_name', p.display_name,
             'in_use', exists (select 1 from public.hunter_devices d where d.hunter_id = p.id and d.user_id <> auth.uid()),
             'mine',   exists (select 1 from public.hunter_devices d where d.hunter_id = p.id and d.user_id = auth.uid()))
           order by lower(p.display_name))
      from public.profiles p where p.is_active), '[]'::jsonb));
end $$;

-- Link this phone to a hunter name (camp code required, name must be free).
create or replace function public.join_camp(code text, hunter uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  r text := public.check_camp_code(code);
  p public.profiles%rowtype;
begin
  if r <> 'ok' then return jsonb_build_object('ok', false, 'error', r); end if;
  select * into p from public.profiles where id = hunter and is_active;
  if not found then return jsonb_build_object('ok', false, 'error', 'no_such_hunter'); end if;
  if exists (select 1 from public.hunter_devices where hunter_id = hunter and user_id <> auth.uid()) then
    return jsonb_build_object('ok', false, 'error', 'in_use');
  end if;
  insert into public.hunter_devices (user_id, hunter_id) values (auth.uid(), hunter)
  on conflict (user_id) do update set hunter_id = excluded.hunter_id, linked_at = now(), last_seen_at = now();
  return jsonb_build_object('ok', true, 'hunter',
    jsonb_build_object('id', p.id, 'display_name', p.display_name, 'is_admin', p.is_admin));
end $$;

-- Who this phone is signed in as (null hunter when not linked or deactivated).
create or replace function public.whoami()
returns jsonb language plpgsql security definer set search_path = public as $$
declare p public.profiles%rowtype;
begin
  select pr.* into p from public.hunter_devices d join public.profiles pr on pr.id = d.hunter_id
   where d.user_id = auth.uid() and pr.is_active;
  if not found then return jsonb_build_object('hunter', null); end if;
  update public.hunter_devices set last_seen_at = now() where user_id = auth.uid();
  return jsonb_build_object('hunter', jsonb_build_object('id', p.id, 'display_name', p.display_name, 'is_admin', p.is_admin));
end $$;

-- "Switch hunter" on this phone: frees the name for use on another phone.
create or replace function public.leave_camp()
returns void language sql security definer set search_path = public as $$
  delete from public.hunter_devices where user_id = auth.uid();
$$;

-- Admin: free a hunter's name (lost phone, new phone).
create or replace function public.release_hunter(hunter uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Only the camp administrator can do this' using errcode = '42501'; end if;
  delete from public.hunter_devices where hunter_id = hunter;
end $$;

-- Admin (or the SQL Editor): set the camp code. At least 6 characters.
create or replace function public.set_camp_code(code text)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  if auth.uid() is not null and not public.is_admin() then
    raise exception 'Only the camp administrator can change the camp code' using errcode = '42501';
  end if;
  if code is null or char_length(btrim(code)) < 6 then
    raise exception 'The camp code must be at least 6 characters' using errcode = 'check_violation';
  end if;
  update public.camp_settings set code_hash = crypt(btrim(code), gen_salt('bf')), updated_at = now() where id = 1;
  delete from public.join_attempts;
end $$;

-- Admin: hunters with whether their name is in use on a phone.
create or replace function public.hunter_list()
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Only the camp administrator can do this' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', p.id, 'display_name', p.display_name, 'is_admin', p.is_admin, 'is_active', p.is_active,
             'in_use', d.user_id is not null, 'last_seen_at', d.last_seen_at)
           order by p.is_active desc, lower(p.display_name))
      from public.profiles p left join public.hunter_devices d on d.hunter_id = p.id), '[]'::jsonb);
end $$;

revoke all on function public.check_camp_code(text), public.camp_roster(text), public.join_camp(text, uuid),
  public.whoami(), public.leave_camp(), public.release_hunter(uuid), public.set_camp_code(text),
  public.hunter_list(), public.current_hunter_id() from public, anon;
grant execute on function public.camp_roster(text), public.join_camp(text, uuid), public.whoami(),
  public.leave_camp(), public.release_hunter(uuid), public.set_camp_code(text), public.hunter_list(),
  public.current_hunter_id() to authenticated;

-- ===== 20261125000004_admin_pin.sql =====
-- Deer Camp — separate administrator PIN (version 4)
--
-- The camp code is shared with every hunter. Joining as a name marked
-- "administrator" now also needs the ADMIN PIN, so a hunter who knows the
-- camp code cannot take over an administrator name.
--  * Stored only as a bcrypt hash; must be different from the camp code.
--  * Wrong admin PINs count toward the same 5-tries / 15-minutes lock-out.
--  * Phones already joined as an administrator stay joined.
-- Run this AFTER migrations 1, 2 and 3. Safe to run more than once.

alter table public.camp_settings add column if not exists admin_pin_hash text;

-- Internal: count a wrong admin PIN toward the phone's lock-out.
create or replace function public.note_failed_try()
returns void language sql security definer set search_path = public as $$
  insert into public.join_attempts (user_id, failures, last_failure_at) values (auth.uid(), 1, now())
  on conflict (user_id) do update set
    failures = case when public.join_attempts.last_failure_at < now() - interval '15 minutes'
                    then 1 else public.join_attempts.failures + 1 end,
    last_failure_at = now();
$$;

-- Admin (or the SQL Editor): set the administrator PIN. At least 6 characters,
-- and not the same as the camp code.
create or replace function public.set_admin_pin(pin text)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare h text;
begin
  if auth.uid() is not null and not public.is_admin() then
    raise exception 'Only the camp administrator can change the admin PIN' using errcode = '42501';
  end if;
  if pin is null or char_length(btrim(pin)) < 6 then
    raise exception 'The admin PIN must be at least 6 characters' using errcode = 'check_violation';
  end if;
  select code_hash into h from public.camp_settings where id = 1;
  if h is not null and crypt(btrim(pin), h) = h then
    raise exception 'The admin PIN must be different from the camp code' using errcode = 'check_violation';
  end if;
  update public.camp_settings set admin_pin_hash = crypt(btrim(pin), gen_salt('bf')), updated_at = now() where id = 1;
end $$;

-- The camp code may not be the same as the admin PIN either.
create or replace function public.set_camp_code(code text)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare h text;
begin
  if auth.uid() is not null and not public.is_admin() then
    raise exception 'Only the camp administrator can change the camp code' using errcode = '42501';
  end if;
  if code is null or char_length(btrim(code)) < 6 then
    raise exception 'The camp code must be at least 6 characters' using errcode = 'check_violation';
  end if;
  select admin_pin_hash into h from public.camp_settings where id = 1;
  if h is not null and crypt(btrim(code), h) = h then
    raise exception 'The camp code must be different from the admin PIN' using errcode = 'check_violation';
  end if;
  update public.camp_settings set code_hash = crypt(btrim(code), gen_salt('bf')), updated_at = now() where id = 1;
  delete from public.join_attempts;
end $$;

-- The roster now says which names are administrators (the app then asks for the PIN).
create or replace function public.camp_roster(code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r text := public.check_camp_code(code);
begin
  if r <> 'ok' then return jsonb_build_object('ok', false, 'error', r); end if;
  return jsonb_build_object('ok', true, 'hunters', coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', p.id,
             'display_name', p.display_name,
             'is_admin', p.is_admin,
             'in_use', exists (select 1 from public.hunter_devices d where d.hunter_id = p.id and d.user_id <> auth.uid()),
             'mine',   exists (select 1 from public.hunter_devices d where d.hunter_id = p.id and d.user_id = auth.uid()))
           order by lower(p.display_name))
      from public.profiles p where p.is_active), '[]'::jsonb));
end $$;

-- Joining as an administrator name needs the admin PIN as well.
drop function if exists public.join_camp(text, uuid);
create or replace function public.join_camp(code text, hunter uuid, admin_pin text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  r text := public.check_camp_code(code);
  p public.profiles%rowtype;
  h text;
begin
  if r <> 'ok' then return jsonb_build_object('ok', false, 'error', r); end if;
  select * into p from public.profiles where id = hunter and is_active;
  if not found then return jsonb_build_object('ok', false, 'error', 'no_such_hunter'); end if;
  if exists (select 1 from public.hunter_devices where hunter_id = hunter and user_id <> auth.uid()) then
    return jsonb_build_object('ok', false, 'error', 'in_use');
  end if;
  if p.is_admin and not exists (select 1 from public.hunter_devices where hunter_id = hunter and user_id = auth.uid()) then
    select admin_pin_hash into h from public.camp_settings where id = 1;
    if h is null then return jsonb_build_object('ok', false, 'error', 'admin_pin_not_set'); end if;
    if admin_pin is null or btrim(admin_pin) = '' then return jsonb_build_object('ok', false, 'error', 'admin_pin_needed'); end if;
    if crypt(btrim(admin_pin), h) <> h then
      perform public.note_failed_try();
      return jsonb_build_object('ok', false, 'error', 'wrong_admin_pin');
    end if;
  end if;
  insert into public.hunter_devices (user_id, hunter_id) values (auth.uid(), hunter)
  on conflict (user_id) do update set hunter_id = excluded.hunter_id, linked_at = now(), last_seen_at = now();
  return jsonb_build_object('ok', true, 'hunter',
    jsonb_build_object('id', p.id, 'display_name', p.display_name, 'is_admin', p.is_admin));
end $$;

revoke all on function public.note_failed_try(), public.set_admin_pin(text), public.set_camp_code(text),
  public.camp_roster(text), public.join_camp(text, uuid, text) from public, anon;
grant execute on function public.set_admin_pin(text), public.set_camp_code(text), public.camp_roster(text),
  public.join_camp(text, uuid, text) to authenticated;

