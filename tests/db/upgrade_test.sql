-- Upgrade check: a sighting saved before migration 2 (one type + quantity)
-- gets correct per-type counts when migration 2 runs.
\set ON_ERROR_STOP on
do $$ begin
  if (select doe_count from public.deer_sightings where id = '88888888-8888-4888-8888-888888888888') is distinct from 2 then
    raise exception 'UPGRADE FAILED: legacy sighting not converted';
  end if;
  raise notice 'ok: legacy sighting converted to per-type counts';
  if not exists (select 1 from public.hunter_devices
                 where user_id = '00000000-0000-4000-8000-0000000000f1' and hunter_id = '00000000-0000-4000-8000-0000000000f1') then
    raise exception 'UPGRADE FAILED: e-mail account not linked as a phone';
  end if;
  raise notice 'ok: existing e-mail account keeps working after the camp-code change';
end $$;
