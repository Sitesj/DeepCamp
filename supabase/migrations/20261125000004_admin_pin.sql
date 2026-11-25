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
