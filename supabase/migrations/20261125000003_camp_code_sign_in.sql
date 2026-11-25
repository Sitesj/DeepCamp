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
-- Run this AFTER migrations 1 and 2.
-- Supabase: Authentication → Sign In / Providers → turn ON "Allow anonymous sign-ins".

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------
create table public.camp_settings (
  id          integer primary key default 1 check (id = 1),
  code_hash   text,
  updated_at  timestamptz not null default now()
);
insert into public.camp_settings (id) values (1) on conflict do nothing;

-- Which hunter each phone (Supabase auth user) is signed in as.
create table public.hunter_devices (
  user_id       uuid primary key references auth.users (id) on delete cascade,
  hunter_id     uuid not null references public.profiles (id) on delete cascade,
  linked_at     timestamptz not null default now(),
  last_seen_at  timestamptz not null default now()
);
create unique index hunter_devices_one_phone_per_hunter on public.hunter_devices (hunter_id);

-- Wrong camp-code attempts per phone (lock-out after 5 within 15 minutes).
create table public.join_attempts (
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
