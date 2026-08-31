#!/usr/bin/env bash
# WP-1 self-test for the migration runner.
#
# Proves the four properties the runner exists to guarantee:
#   1. a database can be built from empty and torn back down to empty
#   2. rebuilding after a teardown produces the same schema
#   3. a migration that has been edited after being applied is refused
#   4. a migration inserted below the highest applied version is refused
#   5. a migration without a rollback script is refused at plan time
#
# Runs against a scratch database that is dropped and recreated, so it never
# touches the development database.
#
# Usage: scripts/selftest_migrations.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
ADMIN_URL="${DHAAGA_ADMIN_URL:-postgres://postgres@127.0.0.1:5433/postgres}"
SCRATCH_DB="dhaaga_migrate_selftest"
export DHAAGA_DB_URL="${ADMIN_URL%/*}/${SCRATCH_DB}"

PASS=0
FAIL=0
GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; RESET=$'\033[0m'

pass() { PASS=$((PASS+1)); printf '%sok%s    %s\n' "$GREEN" "$RESET" "$1"; }
fail() { FAIL=$((FAIL+1)); printf '%sFAIL%s  %s\n      %s\n' "$RED" "$RESET" "$1" "${2:-}"; }

check() { # name, expect_success(0/1), command...
  local name="$1" expect="$2"; shift 2
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  if [ "$expect" -eq 0 ] && [ $rc -eq 0 ]; then pass "$name"
  elif [ "$expect" -ne 0 ] && [ $rc -ne 0 ]; then pass "$name ${DIM}(refused as designed)${RESET}"
  else fail "$name" "$(echo "$out" | tail -3)"; fi
}

psql "$ADMIN_URL" -q -c "drop database if exists $SCRATCH_DB;" -c "create database $SCRATCH_DB;" >/dev/null 2>&1

echo
echo "WP-1 migration runner self-test"
echo

# ---- 1. build from empty -----------------------------------------------------
check "migrate up from empty database"            0 python3 "$REPO/scripts/migrate.py" up
# A fingerprint, not a table count: covers tables, columns and their types,
# functions, domains and constraints, so a rebuild that quietly differs is caught.
FINGERPRINT_SQL="
with cols as (
    select table_schema||'.'||table_name||'.'||column_name||':'||data_type||
           coalesce(':'||character_maximum_length::text,'')||':'||is_nullable as sig
    from information_schema.columns where table_schema in ('public','app')),
routines as (
    select n.nspname||'.'||p.proname||'('||pg_get_function_identity_arguments(p.oid)||')' as sig
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('public','app')),
doms as (
    select n.nspname||'.'||t.typname as sig
    from pg_type t join pg_namespace n on n.oid = t.typnamespace
    where n.nspname in ('public','app') and t.typtype = 'd'),
cons as (
    select c.conrelid::regclass::text||':'||c.conname||':'||pg_get_constraintdef(c.oid) as sig
    from pg_constraint c join pg_namespace n on n.oid = c.connamespace
    where n.nspname in ('public','app'))
select md5(string_agg(sig, E'\n' order by sig))
from (select sig from cols union all select sig from routines
      union all select sig from doms union all select sig from cons) all_sigs;"
BUILT="$(psql "$DHAAGA_DB_URL" -t -A -c "$FINGERPRINT_SQL" 2>&1)"
# Guard: an empty or non-hash fingerprint means the fingerprint query itself broke.
# Without this, a broken query compares "" to "" and passes vacuously.
if [[ ! "$BUILT" =~ ^[0-9a-f]{32}$ ]]; then
  fail "schema fingerprint query is valid" "got: $BUILT"
else
  pass "schema fingerprint query is valid ${DIM}(${BUILT:0:12})${RESET}"
fi

# ---- 2. verify passes on a clean tree ---------------------------------------
check "verify on an intact tree"                  0 python3 "$REPO/scripts/migrate.py" verify

# ---- 3. tear down to empty ---------------------------------------------------
check "migrate down to empty database"            0 python3 "$REPO/scripts/migrate.py" reset
REMAINING="$(psql "$DHAAGA_DB_URL" -t -A -c "select count(*) from information_schema.tables where table_schema in ('app');")"
if [ "$REMAINING" = "0" ]; then pass "rollback left no application objects behind"
else fail "rollback left no application objects behind" "$REMAINING objects remain in schema app"; fi

# ---- 4. rebuild reproduces the same schema ----------------------------------
check "re-migrate after teardown"                 0 python3 "$REPO/scripts/migrate.py" up
REBUILT="$(psql "$DHAAGA_DB_URL" -t -A -c "$FINGERPRINT_SQL" 2>&1)"
if [[ "$BUILT" =~ ^[0-9a-f]{32}$ ]] && [ "$BUILT" = "$REBUILT" ]; then
  pass "rebuilt schema fingerprint matches first build ${DIM}(${BUILT:0:12})${RESET}"
else
  fail "rebuilt schema fingerprint matches first build" "first build '$BUILT', rebuild '$REBUILT'"
fi

# ---- 5. an edited migration is refused --------------------------------------
TAMPER="$REPO/db/migrations/0002_app_foundation.sql"
cp "$TAMPER" /tmp/dhaaga_tamper.bak
printf '\n-- tampered by selftest\n' >> "$TAMPER"
check "edited applied migration is refused"       1 python3 "$REPO/scripts/migrate.py" verify
cp /tmp/dhaaga_tamper.bak "$TAMPER"; rm -f /tmp/dhaaga_tamper.bak
check "verify passes again once restored"         0 python3 "$REPO/scripts/migrate.py" verify

# ---- 6. an out-of-order migration is refused --------------------------------
OOO_UP="$REPO/db/migrations/0000_out_of_order.sql"
OOO_DOWN="$REPO/db/rollback/0000_out_of_order.down.sql"
echo "select 1;" > "$OOO_UP"; echo "select 1;" > "$OOO_DOWN"
check "out-of-order migration is refused"         1 python3 "$REPO/scripts/migrate.py" up
rm -f "$OOO_UP" "$OOO_DOWN"

# ---- 7. a migration without a rollback is refused ---------------------------
ORPHAN="$REPO/db/migrations/9999_orphan.sql"
echo "select 1;" > "$ORPHAN"
check "migration without rollback script refused" 1 python3 "$REPO/scripts/migrate.py" up
rm -f "$ORPHAN"

# ---- 8. tree is clean at the end --------------------------------------------
check "final verify"                              0 python3 "$REPO/scripts/migrate.py" verify

psql "$ADMIN_URL" -q -c "drop database if exists $SCRATCH_DB;" >/dev/null 2>&1

echo
if [ "$FAIL" -gt 0 ]; then
  printf '%sFAILED%s  %d passed, %d failed\n\n' "$RED" "$RESET" "$PASS" "$FAIL"; exit 1
fi
printf '%sPASSED%s  %d checks\n\n' "$GREEN" "$RESET" "$PASS"
