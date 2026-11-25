#!/usr/bin/env bash
# Rebuilds supabase/setup-all-in-one.sql from the migrations (run after changing a migration).
set -euo pipefail
cd "$(dirname "$0")/../.."
{
  printf -- '-- Deer Camp: complete database setup for a NEW Supabase project.\n-- This is migrations 1, 2 and 3 from supabase/migrations/ joined together.\n-- Paste it all into SQL Editor -> New query -> Run (once).\n-- Regenerate with: bash tests/db/build_all_in_one.sh\n\n'
  for f in supabase/migrations/*.sql; do
    printf -- '-- ===== %s =====\n' "$(basename "$f")"; cat "$f"; printf '\n'
  done
} > "${1:-supabase/setup-all-in-one.sql}"
