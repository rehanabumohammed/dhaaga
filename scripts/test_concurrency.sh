#!/usr/bin/env bash
# Concurrency tests — the ones the single-session SQL suite cannot express.
#
# db/tests/*.sql all run inside one transaction on one connection, which is what
# makes them fast and isolated. It also makes them structurally incapable of
# testing a race: a race needs two connections contending for the same row.
#
# This harness runs those cases against a scratch database that is created and
# dropped here, so it never touches development data.
#
# Case 1 · Two concurrent reversals of the same journal entry.
#   Invariant: one original entry -> zero or one reversal, never two.
#   Expected: the first commits, the second blocks on the unique index and is
#   then rejected. Exactly one reversal exists and the ledger still nets zero.
#
# Case 2 · Two concurrent number-lease allocations from one series.
#   Invariant: two devices never hold overlapping document numbers.
#
# Usage: scripts/test_concurrency.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
ADMIN_URL="${DHAAGA_ADMIN_URL:-postgres://postgres@127.0.0.1:5433/postgres}"
SCRATCH="dhaaga_concurrency"
URL="${ADMIN_URL%/*}/${SCRATCH}"

PASS=0; FAIL=0
GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; RESET=$'\033[0m'
pass() { PASS=$((PASS+1)); printf '%sok%s    %s\n' "$GREEN" "$RESET" "$1"; }
fail() { FAIL=$((FAIL+1)); printf '%sFAIL%s  %s\n      %s\n' "$RED" "$RESET" "$1" "${2:-}"; }

cleanup() { psql "$ADMIN_URL" -q -c "drop database if exists $SCRATCH with (force);" >/dev/null 2>&1; }
trap cleanup EXIT

echo
echo "Concurrency tests"
echo

psql "$ADMIN_URL" -q -c "drop database if exists $SCRATCH with (force);" >/dev/null 2>&1
psql "$ADMIN_URL" -q -c "create database $SCRATCH;" >/dev/null 2>&1
DHAAGA_DB_URL="$URL" python3 "$REPO/scripts/migrate.py" up >/dev/null 2>&1 \
  || { fail "scratch database migrated" "migration failed"; exit 1; }
pass "scratch database built from empty ${DIM}($SCRATCH)${RESET}"

# ---------------------------------------------------------------------------
# Fixtures, committed so both sessions can see them
# ---------------------------------------------------------------------------
psql "$URL" -q --no-psqlrc >/dev/null 2>&1 <<'SQL'
insert into business (id, legal_name) values ('11111111-1111-1111-1111-111111111111','Concurrency Co');
insert into branch (id, business_id, code, name)
values ('22222222-2222-2222-2222-222222222222','11111111-1111-1111-1111-111111111111','BR1','Main');
insert into account (id, business_id, code, name, account_type, normal_balance) values
 ('a0000000-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','1100','Cash','asset','debit'),
 ('a0000000-0000-0000-0000-000000000002','11111111-1111-1111-1111-111111111111','4100','Sales','revenue','credit');
select app.post_entry('11111111-1111-1111-1111-111111111111','22222222-2222-2222-2222-222222222222',
  'payment', null, 'The entry both sessions will race to reverse',
  jsonb_build_array(jsonb_build_object('account_id','a0000000-0000-0000-0000-000000000001','debit',5000),
                    jsonb_build_object('account_id','a0000000-0000-0000-0000-000000000002','credit',5000)));
insert into device (id, business_id, label, platform) values
 ('d0000000-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','Device one','android'),
 ('d0000000-0000-0000-0000-000000000002','11111111-1111-1111-1111-111111111111','Device two','android');
insert into number_series (id, business_id, branch_id, doc_type, financial_year, prefix, is_offline_leasable)
values ('50000000-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111',
        '22222222-2222-2222-2222-222222222222','order_token','2026-27','BR1-',true);
SQL

ENTRY_ID="$(psql "$URL" -tA -c "select id from journal_entry where reversal_of_id is null limit 1;")"
[ -n "$ENTRY_ID" ] && pass "fixture entry posted ${DIM}(${ENTRY_ID:0:8})${RESET}" \
                   || { fail "fixture entry posted" "no entry"; exit 1; }

# ---------------------------------------------------------------------------
# Case 1 · two concurrent reversals of the same entry
# ---------------------------------------------------------------------------
# Session A holds its transaction open for three seconds after reversing, so B
# is guaranteed to contend rather than merely follow.
(
  psql "$URL" -q --no-psqlrc -v ON_ERROR_STOP=1 <<SQL >/tmp/dh_sess_a.log 2>&1
begin;
select app.reverse_journal_entry('$ENTRY_ID', 'session_a');
select pg_sleep(3);
commit;
SQL
) &
A_PID=$!

sleep 1

psql "$URL" -q --no-psqlrc -v ON_ERROR_STOP=1 <<SQL >/tmp/dh_sess_b.log 2>&1
select app.reverse_journal_entry('$ENTRY_ID', 'session_b');
SQL
B_RC=$?

wait $A_PID
A_RC=$?

if [ $A_RC -eq 0 ]; then pass "the first session's reversal committed"
else fail "the first session's reversal committed" "$(tail -2 /tmp/dh_sess_a.log)"; fi

if [ $B_RC -ne 0 ]; then
  if grep -qi 'duplicate key\|unique constraint' /tmp/dh_sess_b.log; then
    pass "the second session was rejected by the unique constraint ${DIM}(not by luck)${RESET}"
  else
    fail "the second session was rejected by the unique constraint" "$(tail -3 /tmp/dh_sess_b.log)"
  fi
else
  fail "the second session was rejected" "it SUCCEEDED - two reversals of one entry"
fi

REVERSALS="$(psql "$URL" -tA -c "select count(*) from journal_entry where reversal_of_id = '$ENTRY_ID';")"
[ "$REVERSALS" = "1" ] && pass "exactly one reversal exists after the race ${DIM}(invariant held)${RESET}" \
                       || fail "exactly one reversal exists after the race" "found $REVERSALS"

NET="$(psql "$URL" -tA -c "select coalesce(sum(debit) - sum(credit), 0) from journal_line;")"
[ "$NET" = "0.00" ] || [ "$NET" = "0" ] \
  && pass "the ledger still nets to zero ${DIM}(no duplicate financial effect)${RESET}" \
  || fail "the ledger still nets to zero" "net movement is $NET"

CASH="$(psql "$URL" -tA -c "
  select coalesce(sum(l.debit) - sum(l.credit), 0) from journal_line l
  join account a on a.id = l.account_id where a.code = '1100';")"
[ "$CASH" = "0.00" ] || [ "$CASH" = "0" ] \
  && pass "cash nets to zero: the reversal cancelled the original exactly once" \
  || fail "cash nets to zero" "cash balance is $CASH - the entry was reversed twice or not at all"

# ---------------------------------------------------------------------------
# Case 2 · two devices leasing document numbers at the same time
# ---------------------------------------------------------------------------
(
  psql "$URL" -q --no-psqlrc -v ON_ERROR_STOP=1 <<'SQL' >/tmp/dh_lease_a.log 2>&1
begin;
insert into number_lease (business_id, branch_id, series_id, device_id, range_start, range_end, next_value, expires_at)
values ('11111111-1111-1111-1111-111111111111','22222222-2222-2222-2222-222222222222',
        '50000000-0000-0000-0000-000000000001','d0000000-0000-0000-0000-000000000001',
        1, 100, 1, now() + interval '7 days');
select pg_sleep(3);
commit;
SQL
) &
L_PID=$!
sleep 1

psql "$URL" -q --no-psqlrc -v ON_ERROR_STOP=1 <<'SQL' >/tmp/dh_lease_b.log 2>&1
insert into number_lease (business_id, branch_id, series_id, device_id, range_start, range_end, next_value, expires_at)
values ('11111111-1111-1111-1111-111111111111','22222222-2222-2222-2222-222222222222',
        '50000000-0000-0000-0000-000000000001','d0000000-0000-0000-0000-000000000002',
        50, 150, 50, now() + interval '7 days');
SQL
LB_RC=$?
wait $L_PID

if [ $LB_RC -ne 0 ] && grep -qi 'conflicting key\|exclusion constraint' /tmp/dh_lease_b.log; then
  pass "a concurrent overlapping number lease is rejected ${DIM}(exclusion constraint)${RESET}"
else
  fail "a concurrent overlapping number lease is rejected" "$(tail -3 /tmp/dh_lease_b.log)"
fi

LEASES="$(psql "$URL" -tA -c "select count(*) from number_lease;")"
[ "$LEASES" = "1" ] && pass "exactly one lease exists: two devices cannot hold the same numbers" \
                    || fail "exactly one lease exists" "found $LEASES"

# ---------------------------------------------------------------------------
# Case 3 · two managers granting the same person the same access at once
# ---------------------------------------------------------------------------
# Invariant: one (person, branch, role) -> one live grant. Two rows would mean
# revoking one leaves the other standing, which is a revocation that silently
# does nothing - the worst shape a security bug can take.
psql "$URL" -q --no-psqlrc >/dev/null 2>&1 <<'SQL'
insert into app_user (id, business_id, full_name) values
 ('c0000000-0000-0000-0000-000000000009','11111111-1111-1111-1111-111111111111','Granted person');
insert into role (id, business_id, code, name) values
 ('a0000000-0000-0000-0000-00000000f001','11111111-1111-1111-1111-111111111111','staff','Staff');
SQL

(
  psql "$URL" -q --no-psqlrc -v ON_ERROR_STOP=1 <<'SQL' >/tmp/dh_grant_a.log 2>&1
begin;
insert into user_branch_role (business_id, user_id, branch_id, role_id)
values ('11111111-1111-1111-1111-111111111111','c0000000-0000-0000-0000-000000000009',
        '22222222-2222-2222-2222-222222222222','a0000000-0000-0000-0000-00000000f001');
select pg_sleep(3);
commit;
SQL
) &
G_PID=$!
sleep 1

psql "$URL" -q --no-psqlrc -v ON_ERROR_STOP=1 <<'SQL' >/tmp/dh_grant_b.log 2>&1
insert into user_branch_role (business_id, user_id, branch_id, role_id)
values ('11111111-1111-1111-1111-111111111111','c0000000-0000-0000-0000-000000000009',
        '22222222-2222-2222-2222-222222222222','a0000000-0000-0000-0000-00000000f001');
SQL
GB_RC=$?
wait $G_PID

if [ $GB_RC -ne 0 ] && grep -qi 'duplicate key\|unique constraint' /tmp/dh_grant_b.log; then
  pass "a concurrent duplicate branch grant is rejected ${DIM}(unique constraint)${RESET}"
else
  fail "a concurrent duplicate branch grant is rejected" "$(tail -3 /tmp/dh_grant_b.log)"
fi

GRANTS="$(psql "$URL" -tA -c "select count(*) from user_branch_role where user_id = 'c0000000-0000-0000-0000-000000000009' and deleted_at is null;")"
[ "$GRANTS" = "1" ] && pass "exactly one live grant exists, so revoking it revokes everything" \
                    || fail "exactly one live grant exists" "found $GRANTS - a revocation would leave access behind"

# ---------------------------------------------------------------------------
# Case 4 · two devices guessing a PIN at the same time
# ---------------------------------------------------------------------------
# Invariant: the failed-attempt counter counts every attempt. A lost update
# here means the lockout can be outrun by opening a second connection, which
# turns a four-digit PIN back into four digits.
psql "$URL" -q --no-psqlrc >/dev/null 2>&1 <<'SQL'
select app.set_pin('4321','c0000000-0000-0000-0000-000000000009');
SQL

(
  psql "$URL" -q --no-psqlrc <<'SQL' >/tmp/dh_pin_a.log 2>&1
begin;
select app.verify_pin('c0000000-0000-0000-0000-000000000009','0000');
select pg_sleep(2);
commit;
SQL
) &
P_PID=$!
sleep 1
psql "$URL" -q --no-psqlrc -c "select app.verify_pin('c0000000-0000-0000-0000-000000000009','1111');" >/tmp/dh_pin_b.log 2>&1
wait $P_PID

ATTEMPTS="$(psql "$URL" -tA -c "select failed_attempts from user_credential where user_id = 'c0000000-0000-0000-0000-000000000009';")"
[ "$ATTEMPTS" = "2" ] \
  && pass "two concurrent wrong PINs both count ${DIM}(no lost update, so the lockout cannot be outrun)${RESET}" \
  || fail "two concurrent wrong PINs both count" "counter reads $ATTEMPTS, expected 2"

echo
if [ "$FAIL" -gt 0 ]; then
  printf '%sFAILED%s  %d passed, %d failed\n\n' "$RED" "$RESET" "$PASS" "$FAIL"; exit 1
fi
printf '%sPASSED%s  %d checks\n\n' "$GREEN" "$RESET" "$PASS"
