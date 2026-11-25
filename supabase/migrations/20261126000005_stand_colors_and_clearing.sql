-- Deer Camp — stand colors and clearing old records (version 5)
--
--  * Each stand has a color (used for its map marker and its BANG! in replay).
--  * Administrators can permanently delete camp records from before a date
--    (sightings, gunshots, and hunts with nothing left in them). Phones are
--    told the date and drop their own copies of records older than it.
-- Run this AFTER migrations 1–4. Safe to run more than once.

-- ---------------------------------------------------------------------------
-- Stand colors
-- ---------------------------------------------------------------------------
alter table public.stands add column if not exists color text;
alter table public.stands drop constraint if exists stands_color_ok;
alter table public.stands add constraint stands_color_ok check (color is null or color ~ '^#[0-9a-fA-F]{6}$');

-- ---------------------------------------------------------------------------
-- Clearing old records
-- ---------------------------------------------------------------------------
alter table public.camp_settings add column if not exists purged_before timestamptz;

-- A correction keeps working if the record it corrected is cleared.
alter table public.deer_sightings drop constraint if exists deer_sightings_corrects_id_fkey;
alter table public.deer_sightings add constraint deer_sightings_corrects_id_fkey
  foreign key (corrects_id) references public.deer_sightings (id) on delete set null;
alter table public.gunshot_reports drop constraint if exists gunshot_reports_corrects_id_fkey;
alter table public.gunshot_reports add constraint gunshot_reports_corrects_id_fkey
  foreign key (corrects_id) references public.gunshot_reports (id) on delete set null;

-- The audit rule still blocks every edit of an original observation, except
-- the link to a corrected record being cleared by the administrator's purge.
create or replace function public.guard_observation_update()
returns trigger language plpgsql as $$
declare
  old_core jsonb;
  new_core jsonb;
begin
  old_core := to_jsonb(old) - array['status','voided_at','void_reason','updated_at','server_received_at'];
  new_core := to_jsonb(new) - array['status','voided_at','void_reason','updated_at','server_received_at'];
  if coalesce(current_setting('deercamp.purging', true), '') = 'on' then
    old_core := old_core - 'corrects_id';
    new_core := new_core - 'corrects_id';
  end if;
  if old_core is distinct from new_core then
    raise exception 'Original observation % cannot be changed; void it and record a correction instead', old.id
      using errcode = 'check_violation';
  end if;
  if old.status = 'voided' and new.status = 'active' then
    raise exception 'Voided observation % cannot be restored', old.id using errcode = 'check_violation';
  end if;
  if old.status = 'voided' then
    new.voided_at := old.voided_at;
    new.void_reason := old.void_reason;
  end if;
  return new;
end $$;

-- Admin: permanently delete camp records observed before `cutoff`.
create or replace function public.purge_records_before(cutoff timestamptz)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  n_deer int; n_gun int; n_sess int;
begin
  if not public.is_admin() then
    raise exception 'Only the camp administrator can clear camp records' using errcode = '42501';
  end if;
  if cutoff is null or cutoff > now() then
    raise exception 'Choose a date that is not in the future' using errcode = 'check_violation';
  end if;
  perform set_config('deercamp.purging', 'on', true);
  delete from public.gunshot_reports where observed_at < cutoff;
  get diagnostics n_gun = row_count;
  delete from public.deer_sightings where observed_at < cutoff;
  get diagnostics n_deer = row_count;
  delete from public.hunting_sessions s
   where s.started_at < cutoff
     and not exists (select 1 from public.deer_sightings d where d.session_id = s.id)
     and not exists (select 1 from public.gunshot_reports g where g.session_id = s.id);
  get diagnostics n_sess = row_count;
  perform set_config('deercamp.purging', 'off', true);
  update public.camp_settings set purged_before = greatest(coalesce(purged_before, cutoff), cutoff) where id = 1;
  return jsonb_build_object('deer_sightings', n_deer, 'gunshot_reports', n_gun, 'hunting_sessions', n_sess);
end $$;

-- whoami also tells the phone the camp's "cleared before" date.
create or replace function public.whoami()
returns jsonb language plpgsql security definer set search_path = public as $$
declare p public.profiles%rowtype;
        pb timestamptz;
begin
  select purged_before into pb from public.camp_settings where id = 1;
  select pr.* into p from public.hunter_devices d join public.profiles pr on pr.id = d.hunter_id
   where d.user_id = auth.uid() and pr.is_active;
  if not found then return jsonb_build_object('hunter', null, 'purged_before', pb); end if;
  update public.hunter_devices set last_seen_at = now() where user_id = auth.uid();
  return jsonb_build_object('hunter', jsonb_build_object('id', p.id, 'display_name', p.display_name, 'is_admin', p.is_admin),
                            'purged_before', pb);
end $$;

revoke all on function public.purge_records_before(timestamptz), public.whoami() from public, anon;
grant execute on function public.purge_records_before(timestamptz), public.whoami() to authenticated;
