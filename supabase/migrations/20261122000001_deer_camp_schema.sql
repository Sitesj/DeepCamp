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
