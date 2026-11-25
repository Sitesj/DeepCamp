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

# 3) The paste-in files match the migrations
tmpdir="$(mktemp -d)"
trap 'dropdb --if-exists "$db"; dropdb --if-exists "$db2"; rm -rf "$tmpdir"' EXIT
bash "$here/build_all_in_one.sh" "$tmpdir"
for f in setup-all-in-one.sql upgrade-existing-project.sql; do
  if ! diff -q "$tmpdir/$f" "$here/../../supabase/$f" >/dev/null; then
    echo "supabase/$f is out of date: run bash tests/db/build_all_in_one.sh"; exit 1
  fi
done

# Like the Supabase SQL Editor, each paste-in file runs as one transaction (-1).
run_file() { psql -q -1 -v ON_ERROR_STOP=1 -d "$1" -f "$2"; }

# 4) setup-all-in-one.sql on a new project passes the full test suite
d="deercamp_allinone_$$"; createdb "$d"
psql -q -v ON_ERROR_STOP=1 -d "$d" -f "$here/supabase_stub.sql"
run_file "$d" "$here/../../supabase/setup-all-in-one.sql"
psql -q -t -A -v ON_ERROR_STOP=1 -d "$d" -f "$here/rls_test.sql" 2>/dev/null | grep -q "ALL DATABASE TESTS PASSED"
dropdb "$d"
echo "ALL-IN-ONE SETUP TEST PASSED"

# 5) upgrade-existing-project.sql on a project that ran migration 1 only, that also
#    ran the deer-count add-on (2), that ran an earlier upgrade (2+3), and run twice
up="$here/../../supabase/upgrade-existing-project.sql"
for variant in only1 with2 with23 twice; do
  d="deercamp_up_${variant}_$$"; createdb "$d"
  psql -q -v ON_ERROR_STOP=1 -d "$d" -f "$here/supabase_stub.sql"
  psql -q -v ON_ERROR_STOP=1 -d "$d" -f "${migrations[0]}"
  psql -q -v ON_ERROR_STOP=1 -d "$d" -f "$here/upgrade_fixture.sql"
  case "$variant" in
    with2)  run_file "$d" "${migrations[1]}" ;;
    with23) run_file "$d" "${migrations[1]}"; run_file "$d" "${migrations[2]}" ;;
    twice)  run_file "$d" "$up" ;;
  esac
  run_file "$d" "$up"
  psql -q -t -A -v ON_ERROR_STOP=1 -d "$d" -f "$here/upgrade_test.sql" >/dev/null
  dropdb "$d"
  echo "UPGRADE FILE TEST PASSED ($variant)"
done
