#!/usr/bin/env bash
# Applies the Deer Camp migration to a throw-away PostgreSQL database (with a
# small Supabase auth stub) and runs the RLS/constraint tests.
# Usage: PGHOST=... PGPORT=... PGUSER=postgres tests/db/run.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
db="deercamp_test_$$"
createdb "$db"
trap 'dropdb --if-exists "$db"' EXIT
psql -q -v ON_ERROR_STOP=1 -d "$db" -f "$here/supabase_stub.sql"
for f in "$here"/../../supabase/migrations/*.sql; do
  psql -q -v ON_ERROR_STOP=1 -d "$db" -f "$f"
done
psql -q -t -A -v ON_ERROR_STOP=1 -d "$db" -f "$here/rls_test.sql" | grep -v "^$"
