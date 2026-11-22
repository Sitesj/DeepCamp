#!/usr/bin/env bash
# Applies the Deer Camp migrations to throw-away PostgreSQL databases (with a
# small Supabase auth stub) and runs the RLS/constraint and upgrade tests.
# Usage: PGHOST=... PGPORT=... PGUSER=postgres tests/db/run.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
migrations=("$here"/../../supabase/migrations/*.sql)
db="deercamp_test_$$"
db2="deercamp_upgrade_$$"
createdb "$db"
createdb "$db2"
trap 'dropdb --if-exists "$db"; dropdb --if-exists "$db2"' EXIT

# 1) Fresh install: all migrations, then policy/constraint tests
psql -q -v ON_ERROR_STOP=1 -d "$db" -f "$here/supabase_stub.sql"
for f in "${migrations[@]}"; do psql -q -v ON_ERROR_STOP=1 -d "$db" -f "$f"; done
psql -q -t -A -v ON_ERROR_STOP=1 -d "$db" -f "$here/rls_test.sql" | grep -v "^$"

# 2) Upgrade: first migration, existing data, then the later migrations
psql -q -v ON_ERROR_STOP=1 -d "$db2" -f "$here/supabase_stub.sql"
psql -q -v ON_ERROR_STOP=1 -d "$db2" -f "${migrations[0]}"
psql -q -v ON_ERROR_STOP=1 -d "$db2" -f "$here/upgrade_fixture.sql"
for f in "${migrations[@]:1}"; do psql -q -v ON_ERROR_STOP=1 -d "$db2" -f "$f"; done
psql -q -t -A -v ON_ERROR_STOP=1 -d "$db2" -f "$here/upgrade_test.sql"
echo "UPGRADE TEST PASSED"
