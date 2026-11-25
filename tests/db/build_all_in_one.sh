#!/usr/bin/env bash
# Rebuilds the two paste-in-one-go SQL files from supabase/migrations/:
#   supabase/setup-all-in-one.sql         all migrations, for a NEW project
#   supabase/upgrade-existing-project.sql migrations 2+, for a project that ran migration 1
# Usage: bash tests/db/build_all_in_one.sh [outdir]   (outdir defaults to supabase/)
set -euo pipefail
cd "$(dirname "$0")/../.."
out="${1:-supabase}"
migs=(supabase/migrations/*.sql)
{
  printf -- '-- Deer Camp: complete database setup for a NEW Supabase project.\n'
  printf -- '-- This is all the files in supabase/migrations/ joined together.\n'
  printf -- '-- Paste it all into SQL Editor -> New query -> Run.\n'
  printf -- '-- Regenerate with: bash tests/db/build_all_in_one.sh\n\n'
  for f in "${migs[@]}"; do printf -- '-- ===== %s =====\n' "$(basename "$f")"; cat "$f"; printf '\n'; done
} > "$out/setup-all-in-one.sql"
{
  printf -- '-- Deer Camp: UPGRADE for a project that already ran the first setup script\n'
  printf -- '-- (20261122000001_deer_camp_schema.sql). Adds mixed deer groups, camp-code\n'
  printf -- '-- sign-in and the separate admin PIN. Safe to run again if it was run before.\n'
  printf -- '-- Paste it all into SQL Editor -> New query -> Run.\n'
  printf -- '-- Regenerate with: bash tests/db/build_all_in_one.sh\n\n'
  for f in "${migs[@]:1}"; do printf -- '-- ===== %s =====\n' "$(basename "$f")"; cat "$f"; printf '\n'; done
} > "$out/upgrade-existing-project.sql"
