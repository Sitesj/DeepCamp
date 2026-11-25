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

# 3) The all-in-one setup file matches the migrations and passes the same tests
tmp="$(mktemp)"
bash "$here/build_all_in_one.sh" "$tmp"
if ! diff -q "$tmp" "$here/../../supabase/setup-all-in-one.sql" >/dev/null; then
  echo "supabase/setup-all-in-one.sql is out of date: run bash tests/db/build_all_in_one.sh"; exit 1
fi
db3="deercamp_allinone_$$"
createdb "$db3"
trap 'dropdb --if-exists "$db"; dropdb --if-exists "$db2"; dropdb --if-exists "$db3"; rm -f "$tmp"' EXIT
psql -q -v ON_ERROR_STOP=1 -d "$db3" -f "$here/supabase_stub.sql"
psql -q -v ON_ERROR_STOP=1 -d "$db3" -f "$here/../../supabase/setup-all-in-one.sql"
psql -q -t -A -v ON_ERROR_STOP=1 -d "$db3" -f "$here/rls_test.sql" 2>/dev/null | grep -q "ALL DATABASE TESTS PASSED"
echo "ALL-IN-ONE SETUP TEST PASSED"
