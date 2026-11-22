-- Deer Camp — mixed deer groups (version 2)
--
-- One sighting can now hold a group of different deer, e.g. 3 does, 1 buck
-- and 2 fawns. Each sighting stores a count per type; `quantity` is the
-- total and `deer_type` is the single type seen, or 'mixed'.
-- Run this AFTER 20261122000001_deer_camp_schema.sql.

alter table public.deer_sightings
  add column buck_count    integer not null default 0 check (buck_count between 0 and 500),
  add column doe_count     integer not null default 0 check (doe_count between 0 and 500),
  add column fawn_count    integer not null default 0 check (fawn_count between 0 and 500),
  add column unknown_count integer not null default 0 check (unknown_count between 0 and 500);

-- Existing single-type sightings: put their quantity under their type.
-- (The audit trigger blocks edits to original observations, so it is paused
-- for this one-time conversion.)
alter table public.deer_sightings disable trigger sightings_guard;
update public.deer_sightings set
  buck_count    = case when deer_type = 'buck'    then quantity else 0 end,
  doe_count     = case when deer_type = 'doe'     then quantity else 0 end,
  unknown_count = case when deer_type = 'unknown' then quantity else 0 end;
alter table public.deer_sightings enable trigger sightings_guard;

alter table public.deer_sightings drop constraint if exists deer_sightings_deer_type_check;

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
