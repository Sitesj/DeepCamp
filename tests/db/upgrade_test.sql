-- Upgrade check: a sighting saved before migration 2 (one type + quantity)
-- gets correct per-type counts when migration 2 runs.
\set ON_ERROR_STOP on
do $$ begin
  if (select doe_count from public.deer_sightings where id = '88888888-8888-4888-8888-888888888888') is distinct from 2 then
    raise exception 'UPGRADE FAILED: legacy sighting not converted';
  end if;
  raise notice 'ok: legacy sighting converted to per-type counts';
end $$;
