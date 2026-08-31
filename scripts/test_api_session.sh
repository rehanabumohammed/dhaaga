#!/usr/bin/env bash
# API-session security tests.
#
# The SQL suite connects as the schema owner and uses SET ROLE to act as
# `authenticated`. That is enough to exercise row-level security, but it is NOT
# enough to test anything that depends on session_user: the owner's session is
# trusted no matter which role it switches to.
#
# PostgREST does something different. It logs in as `authenticator` — a role
# with no ownership and NOINHERIT — and switches role per request. This harness
# reproduces that shape with a real second login role, so the trust boundary in
# app.session_is_trusted() is tested rather than assumed.
#
# What it proves:
#   * an API session cannot reach the server-side identity override, even by
#     discarding its own token first;
#   * an API session cannot execute the privileged context or ledger functions;
#   * an API session still works normally within its own tenant.
#
# Usage: scripts/test_api_session.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
ADMIN_URL="${DHAAGA_ADMIN_URL:-postgres://postgres@127.0.0.1:5433/postgres}"
SCRATCH="dhaaga_api_session"
OWNER_URL="${ADMIN_URL%/*}/${SCRATCH}"
PROBE_ROLE="dhaaga_api_probe"
PROBE_PASS="probe_$$_$(date +%s 2>/dev/null || echo x)"
HOSTPORT="$(echo "$ADMIN_URL" | sed -E 's#.*@([^/]+)/.*#\1#')"
PROBE_URL="postgres://${PROBE_ROLE}:${PROBE_PASS}@${HOSTPORT}/${SCRATCH}"

PASS=0; FAIL=0
GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; RESET=$'\033[0m'
pass() { PASS=$((PASS+1)); printf '%sok%s    %s\n' "$GREEN" "$RESET" "$1"; }
fail() { FAIL=$((FAIL+1)); printf '%sFAIL%s  %s\n      %s\n' "$RED" "$RESET" "$1" "${2:-}"; }

cleanup() {
  psql "$ADMIN_URL" -q -c "drop database if exists $SCRATCH with (force);" >/dev/null 2>&1
  psql "$ADMIN_URL" -q -c "drop role if exists $PROBE_ROLE;" >/dev/null 2>&1
}
trap cleanup EXIT

echo
echo "API-session security tests"
echo

psql "$ADMIN_URL" -q -c "drop database if exists $SCRATCH with (force);" >/dev/null 2>&1
psql "$ADMIN_URL" -q -c "create database $SCRATCH;" >/dev/null 2>&1
DHAAGA_DB_URL="$OWNER_URL" python3 "$REPO/scripts/migrate.py" up >/dev/null 2>&1 \
  || { fail "scratch database migrated" "migration failed"; exit 1; }
pass "scratch database built from empty"

# A login role shaped like PostgREST's authenticator: no ownership, NOINHERIT,
# able to switch into the API roles and nothing else.
psql "$ADMIN_URL" -q >/dev/null 2>&1 <<SQL
drop role if exists $PROBE_ROLE;
create role $PROBE_ROLE login noinherit password '$PROBE_PASS';
grant anon, authenticated to $PROBE_ROLE;
SQL
psql "$OWNER_URL" -q -c "grant connect on database $SCRATCH to $PROBE_ROLE;" >/dev/null 2>&1

# Two businesses and a user in each.
psql "$OWNER_URL" -q --no-psqlrc >/dev/null 2>&1 <<'SQL'
insert into business (id, legal_name) values
 ('aaaa1111-0000-0000-0000-000000000001','Business A'),
 ('bbbb1111-0000-0000-0000-000000000001','Business B');
insert into branch (id, business_id, code, name) values
 ('aaaa1111-0000-0000-0000-000000000002','aaaa1111-0000-0000-0000-000000000001','A1','A one'),
 ('bbbb1111-0000-0000-0000-000000000002','bbbb1111-0000-0000-0000-000000000001','B1','B one');
insert into app_user (id, business_id, auth_user_id, full_name) values
 ('aaaa1111-0000-0000-0000-000000000003','aaaa1111-0000-0000-0000-000000000001',
  'a0000000-0000-0000-0000-0000000000a3','User A'),
 ('bbbb1111-0000-0000-0000-000000000003','bbbb1111-0000-0000-0000-000000000001',
  'b0000000-0000-0000-0000-0000000000b3','User B');
insert into role (id, business_id, code, name) values
 ('aaaa1111-0000-0000-0000-000000000004','aaaa1111-0000-0000-0000-000000000001','staff','Staff'),
 ('bbbb1111-0000-0000-0000-000000000004','bbbb1111-0000-0000-0000-000000000001','staff','Staff');
insert into user_branch_role (business_id, user_id, branch_id, role_id) values
 ('aaaa1111-0000-0000-0000-000000000001','aaaa1111-0000-0000-0000-000000000003','aaaa1111-0000-0000-0000-000000000002','aaaa1111-0000-0000-0000-000000000004'),
 ('bbbb1111-0000-0000-0000-000000000001','bbbb1111-0000-0000-0000-000000000003','bbbb1111-0000-0000-0000-000000000002','bbbb1111-0000-0000-0000-000000000004');
insert into customer (business_id, display_name) values
 ('aaaa1111-0000-0000-0000-000000000001','A customer'),
 ('bbbb1111-0000-0000-0000-000000000001','B CONFIDENTIAL');
insert into config_setting (id, business_id, key, category, scope, value_type,
                            default_value, current_value, required_permission) values
 ('aaaa1111-0000-0000-0000-00000000000e','aaaa1111-0000-0000-0000-000000000001',
  'probe.buffer_days','production','business','integer','1','1','config.manage');
insert into validation_signoff (business_id, domain, validated_by_name, validated_on, config_hash)
 values ('bbbb1111-0000-0000-0000-000000000001','tax','B''s CA', current_date,
         app.config_hash('tax','bbbb1111-0000-0000-0000-000000000001'));
SQL

api() { psql "$PROBE_URL" -tA --no-psqlrc -v ON_ERROR_STOP=1 -c "$1" 2>&1; }

# --- the session really is untrusted -----------------------------------------
R="$(api "set role authenticated; select app.session_is_trusted();" | tail -1)"
[ "$R" = "f" ] && pass "an API session is untrusted ${DIM}(session_user is not the schema owner)${RESET}" \
               || fail "an API session is untrusted" "session_is_trusted returned '$R'"

R="$(psql "$OWNER_URL" -tA -c "select app.session_is_trusted();" 2>&1 | tail -1)"
[ "$R" = "t" ] && pass "an owner session remains trusted ${DIM}(migrations and jobs still work)${RESET}" \
               || fail "an owner session remains trusted" "returned '$R'"

# --- the impersonation path, attempted for real ------------------------------
R="$(api "
set role authenticated;
select set_config('request.jwt.claims', '{\"sub\":\"a0000000-0000-0000-0000-0000000000a3\",\"role\":\"authenticated\"}', true);
select coalesce(app.current_user_id()::text,'null');")"
R="$(echo "$R" | tail -1)"
[ "$R" = "aaaa1111-0000-0000-0000-000000000003" ] \
  && pass "with a token, the API session is the token's subject" \
  || fail "with a token, the API session is the token's subject" "got '$R'"

R="$(api "
set role authenticated;
select set_config('request.jwt.claims', '{\"sub\":\"a0000000-0000-0000-0000-0000000000a3\",\"role\":\"authenticated\"}', true);
select set_config('app.actor_id', 'bbbb1111-0000-0000-0000-000000000003', true);
select coalesce(app.current_user_id()::text,'null');")"
R="$(echo "$R" | tail -1)"
[ "$R" = "aaaa1111-0000-0000-0000-000000000003" ] \
  && pass "setting app.actor_id alongside a token changes nothing" \
  || fail "setting app.actor_id alongside a token changes nothing" "got '$R'"

# The residual path from the gate: drop your own token, then claim to be someone.
R="$(api "
set role authenticated;
select set_config('request.jwt.claims', '', true);
select set_config('app.actor_id', 'bbbb1111-0000-0000-0000-000000000003', true);
select coalesce(app.current_user_id()::text,'null');")"
R="$(echo "$R" | tail -1)"
[ "$R" = "null" ] \
  && pass "discarding the token and claiming an identity yields NOBODY ${DIM}(path closed)${RESET}" \
  || fail "discarding the token and claiming an identity yields nobody" "became '$R'"

R="$(api "
set role authenticated;
select set_config('request.jwt.claims', '', true);
select set_config('app.actor_id', 'bbbb1111-0000-0000-0000-000000000003', true);
select count(*) from customer where business_id = 'bbbb1111-0000-0000-0000-000000000001';")"
R="$(echo "$R" | tail -1)"
[ "$R" = "0" ] \
  && pass "and reaches none of that business's data" \
  || fail "and reaches none of that business's data" "saw $R rows"

# --- privileged functions are out of reach -----------------------------------
for FN in "app.set_context(null,null,null,null)" \
          "app.post_entry(null,null,'manual_adjustment',null,null,'[]'::jsonb)" \
          "app.reverse_journal_entry(null,'x')"; do
  OUT="$(api "set role authenticated; select $FN;")"
  if echo "$OUT" | grep -qi 'permission denied'; then
    pass "an API session cannot execute ${FN%%(*} ${DIM}(permission denied)${RESET}"
  else
    fail "an API session cannot execute ${FN%%(*}" "$(echo "$OUT" | tail -2)"
  fi
done

# --- normal operation is unaffected ------------------------------------------
R="$(api "
set role authenticated;
select set_config('request.jwt.claims', '{\"sub\":\"a0000000-0000-0000-0000-0000000000a3\",\"role\":\"authenticated\"}', true);
select count(*) from customer;")"
R="$(echo "$R" | tail -1)"
[ "$R" = "1" ] \
  && pass "a legitimate API session still sees exactly its own tenant's rows" \
  || fail "a legitimate API session still sees its own tenant's rows" "saw $R"

R="$(api "
set role authenticated;
select set_config('request.jwt.claims', '{\"sub\":\"a0000000-0000-0000-0000-0000000000a3\",\"role\":\"authenticated\"}', true);
select app.set_request_context(null, 'regular_customer', 'note');
select coalesce(app.current_user_id()::text,'null');")"
R="$(echo "$R" | tail -1)"
[ "$R" = "aaaa1111-0000-0000-0000-000000000003" ] \
  && pass "set_request_context supplies a reason without touching identity" \
  || fail "set_request_context supplies a reason without touching identity" "identity became '$R'"

# --- WP-6 · the configuration surface, from a real API session ----------------
# The SQL suite covers these as the schema owner. Repeated here because the
# permission trigger and the boundary checks are exactly the code an untrusted
# session is expected to defeat, and an owner session is not that.
TOKEN_A='{"sub":"a0000000-0000-0000-0000-0000000000a3","role":"authenticated"}'

OUT="$(api "
set role authenticated;
select set_config('request.jwt.claims', '$TOKEN_A', true);
create temp table config_setting (id uuid, required_permission text);
insert into config_version (business_id, setting_id, value)
  values ('aaaa1111-0000-0000-0000-000000000001','aaaa1111-0000-0000-0000-00000000000e','99');")"
if echo "$OUT" | grep -qi 'requires the config.manage permission'; then
  pass "an API session cannot shadow config_setting to skip the permission trigger ${DIM}(pg_temp is pinned out)${RESET}"
else
  fail "an API session cannot shadow config_setting to skip the permission trigger" "$(echo "$OUT" | tail -3)"
fi

OUT="$(api "
set role authenticated;
select set_config('request.jwt.claims', '$TOKEN_A', true);
select app.validation_status('tax','bbbb1111-0000-0000-0000-000000000001');")"
if echo "$OUT" | grep -qi 'may not read business'; then
  pass "nor ask whether another business's books are signed off ${DIM}(boundary re-asserted)${RESET}"
else
  fail "nor ask whether another business's books are signed off" "$(echo "$OUT" | tail -3)"
fi

OUT="$(api "set role authenticated; select app.config_hash('tax');")"
if echo "$OUT" | grep -qi 'permission denied'; then
  pass "nor execute app.config_hash ${DIM}(permission denied)${RESET}"
else
  fail "nor execute app.config_hash" "$(echo "$OUT" | tail -2)"
fi

R="$(api "
set role authenticated;
select set_config('request.jwt.claims', '$TOKEN_A', true);
select app.config_int('probe.buffer_days');" | tail -1)"
[ "$R" = "1" ] \
  && pass "while reading its own business's configuration normally" \
  || fail "while reading its own business's configuration normally" "got '$R'"

R="$(api "
set role authenticated;
select set_config('request.jwt.claims', '$TOKEN_A', true);
select coalesce(app.validation_status('tax'),'null');" | tail -1)"
[ "$R" = "unvalidated" ] \
  && pass "and its own validation status ${DIM}(unvalidated: no sign-off recorded)${RESET}" \
  || fail "and its own validation status" "got '$R'"

# --- anonymous reaches nothing ------------------------------------------------
OUT="$(api "set role anon; select count(*) from customer;")"
if echo "$OUT" | grep -qi 'permission denied'; then
  pass "an anonymous session is refused at the table ${DIM}(no privilege, not merely no rows)${RESET}"
else
  fail "an anonymous session is refused at the table" "$(echo "$OUT" | tail -2)"
fi

echo
if [ "$FAIL" -gt 0 ]; then
  printf '%sFAILED%s  %d passed, %d failed\n\n' "$RED" "$RESET" "$PASS" "$FAIL"; exit 1
fi
printf '%sPASSED%s  %d checks\n\n' "$GREEN" "$RESET" "$PASS"
