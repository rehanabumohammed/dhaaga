#!/usr/bin/env bash
# WP-7 adversarial identity probe.
#
# Attacks the identity and authorization model from a REAL untrusted API
# session: a separate login role with NOINHERIT that switches into `anon` and
# `authenticated` per statement, which is the shape PostgREST connects with.
# The SQL suite runs as the schema owner and cannot express this - an owner is
# trusted whichever role it switches into.
#
# Two rules this harness follows, both learned the hard way:
#
#   * A verdict is decided by STATE, never by whether the statement raised.
#     Under row-level security a forbidden UPDATE frequently "succeeds" while
#     matching zero rows; a harness that greps for ERROR calls that a pass and
#     a real exploit that raises a check-constraint error a breach. Every
#     attack below therefore runs, and is then judged by asking the database,
#     as owner, what actually changed.
#   * Damage is repaired between attacks. An exploit that works must not leave
#     the next attack testing a system it has already broken.
#
# Usage: scripts/attack_identity.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
ADMIN_URL="${DHAAGA_ADMIN_URL:-postgres://postgres@127.0.0.1:5433/postgres}"
SCRATCH="dhaaga_attack"
OWNER_URL="${ADMIN_URL%/*}/${SCRATCH}"
PROBE_ROLE="dhaaga_attack_probe"
PROBE_PASS="probe_$$_$(date +%s 2>/dev/null || echo x)"
HOSTPORT="$(echo "$ADMIN_URL" | sed -E 's#.*@([^/]+)/.*#\1#')"
PROBE_URL="postgres://${PROBE_ROLE}:${PROBE_PASS}@${HOSTPORT}/${SCRATCH}"

PASS=0; FAIL=0
GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; RESET=$'\033[0m'
held()   { PASS=$((PASS+1)); printf '%sheld%s   %s\n' "$GREEN" "$RESET" "$1"; }
breach() { FAIL=$((FAIL+1)); printf '%sBREACH%s %s\n       %s\n' "$RED" "$RESET" "$1" "${2:-}"; }

cleanup() {
  psql "$ADMIN_URL" -q -c "drop database if exists $SCRATCH with (force);" >/dev/null 2>&1
  psql "$ADMIN_URL" -q -c "drop role if exists $PROBE_ROLE;" >/dev/null 2>&1
}
trap cleanup EXIT

echo
echo "WP-7 adversarial identity probe"
echo

psql "$ADMIN_URL" -q -c "drop database if exists $SCRATCH with (force);" >/dev/null 2>&1
psql "$ADMIN_URL" -q -c "create database $SCRATCH;" >/dev/null 2>&1
DHAAGA_DB_URL="$OWNER_URL" python3 "$REPO/scripts/migrate.py" up >/dev/null 2>&1 \
  || { breach "scratch database migrated" "migration failed"; exit 1; }

psql "$ADMIN_URL" -q >/dev/null 2>&1 <<SQL
drop role if exists $PROBE_ROLE;
create role $PROBE_ROLE login noinherit password '$PROBE_PASS';
grant anon, authenticated to $PROBE_ROLE;
SQL
psql "$OWNER_URL" -q -c "grant connect on database $SCRATCH to $PROBE_ROLE;" >/dev/null 2>&1

# ---------------------------------------------------------------------------
# Fixtures. Two businesses; in A a tailor, a manager holding one branch of two,
# and an owner. Auth ids are deliberately different from app_user ids, so any
# code that confuses the two is caught rather than accidentally working.
# ---------------------------------------------------------------------------
BIZ_A=aaaa0007-0000-0000-0000-000000000001
BIZ_B=bbbb0007-0000-0000-0000-000000000001
BR_A1=aaaa0007-0000-0000-0000-000000000010
BR_A2=aaaa0007-0000-0000-0000-000000000011
BR_B1=bbbb0007-0000-0000-0000-000000000010
U_TAILOR=aaaa0007-0000-0000-0000-000000000020
U_MGR=aaaa0007-0000-0000-0000-000000000021
U_OWNER=aaaa0007-0000-0000-0000-000000000022
U_B=bbbb0007-0000-0000-0000-000000000020
AUTH_TAILOR=11110007-0000-0000-0000-000000000020
AUTH_MGR=11110007-0000-0000-0000-000000000021
AUTH_OWNER=11110007-0000-0000-0000-000000000022
AUTH_B=22220007-0000-0000-0000-000000000020
R_TAILOR=aaaa0007-0000-0000-0000-000000000030
R_MGR=aaaa0007-0000-0000-0000-000000000031
R_OWNER=aaaa0007-0000-0000-0000-000000000032
R_B=bbbb0007-0000-0000-0000-000000000030
P_ORDER=aaaa0007-0000-0000-0000-000000000040
P_TAXCFG=aaaa0007-0000-0000-0000-000000000041
P_USERMGR=aaaa0007-0000-0000-0000-000000000042
P_ROLEMGR=aaaa0007-0000-0000-0000-000000000043
P_B_TAXCFG=bbbb0007-0000-0000-0000-000000000041

# auth_user_id and app_user.status handling arrive with 0016; the harness runs
# against the schema before and after so the same file proves both states.
HAS_AUTH_COL="$(psql "$OWNER_URL" -tA -c "select count(*) from information_schema.columns where table_name='app_user' and column_name='auth_user_id';" 2>/dev/null)"

seed_fixtures() {
psql "$OWNER_URL" -q --no-psqlrc >/dev/null 2>&1 <<SQL
insert into business (id, legal_name) values ('$BIZ_A','Attack A'), ('$BIZ_B','Attack B');
insert into branch (id, business_id, code, name) values
 ('$BR_A1','$BIZ_A','A1','A one'), ('$BR_A2','$BIZ_A','A2','A two'), ('$BR_B1','$BIZ_B','B1','B one');
insert into app_user (id, business_id, full_name) values
 ('$U_TAILOR','$BIZ_A','A tailor'), ('$U_MGR','$BIZ_A','A manager'),
 ('$U_OWNER','$BIZ_A','A owner'),  ('$U_B','$BIZ_B','B owner');
insert into role (id, business_id, code, name) values
 ('$R_TAILOR','$BIZ_A','tailor','Tailor'), ('$R_MGR','$BIZ_A','branch_manager','Manager'),
 ('$R_OWNER','$BIZ_A','owner','Owner'),    ('$R_B','$BIZ_B','owner','Owner');
insert into permission (id, business_id, code, domain) values
 ('$P_ORDER','$BIZ_A','order.create','order'),
 ('$P_TAXCFG','$BIZ_A','config.tax.manage','config'),
 ('$P_USERMGR','$BIZ_A','user.manage','identity'),
 ('$P_ROLEMGR','$BIZ_A','role.manage','identity'),
 ('$P_B_TAXCFG','$BIZ_B','config.tax.manage','config');
insert into role_permission (business_id, role_id, permission_id) values
 ('$BIZ_A','$R_TAILOR','$P_ORDER'),
 ('$BIZ_A','$R_MGR','$P_ORDER'), ('$BIZ_A','$R_MGR','$P_USERMGR'),
 ('$BIZ_A','$R_OWNER','$P_ORDER'), ('$BIZ_A','$R_OWNER','$P_TAXCFG'),
 ('$BIZ_A','$R_OWNER','$P_USERMGR'), ('$BIZ_A','$R_OWNER','$P_ROLEMGR'),
 ('$BIZ_B','$R_B','$P_B_TAXCFG');
insert into user_branch_role (business_id, user_id, branch_id, role_id) values
 ('$BIZ_A','$U_TAILOR','$BR_A1','$R_TAILOR'),
 ('$BIZ_A','$U_MGR','$BR_A1','$R_MGR'),
 ('$BIZ_A','$U_OWNER','$BR_A1','$R_OWNER'), ('$BIZ_A','$U_OWNER','$BR_A2','$R_OWNER'),
 ('$BIZ_B','$U_B','$BR_B1','$R_B');
insert into customer (business_id, display_name) values
 ('$BIZ_A','A customer'), ('$BIZ_B','B CONFIDENTIAL');
insert into config_setting (business_id, key, category, scope, value_type, default_value, current_value, required_permission)
 values ('$BIZ_A','attack.rule','finance','business','integer','1','1','config.tax.manage');
SQL
if [ "$HAS_AUTH_COL" = "1" ]; then
  psql "$OWNER_URL" -q --no-psqlrc >/dev/null 2>&1 <<SQL
update app_user set auth_user_id = '$AUTH_TAILOR' where id = '$U_TAILOR';
update app_user set auth_user_id = '$AUTH_MGR'    where id = '$U_MGR';
update app_user set auth_user_id = '$AUTH_OWNER'  where id = '$U_OWNER';
update app_user set auth_user_id = '$AUTH_B'      where id = '$U_B';
SQL
fi
}
seed_fixtures

if [ "$HAS_AUTH_COL" = "1" ]; then
  SUB_TAILOR=$AUTH_TAILOR; SUB_MGR=$AUTH_MGR; SUB_OWNER=$AUTH_OWNER; SUB_B=$AUTH_B
else
  SUB_TAILOR=$U_TAILOR; SUB_MGR=$U_MGR; SUB_OWNER=$U_OWNER; SUB_B=$U_B
fi

# --- primitives --------------------------------------------------------------

# as <sub> <sql>  — run SQL in a real API session carrying that subject.
as() {
  local sub="$1"; shift
  psql "$PROBE_URL" -tA --no-psqlrc -c "
set role authenticated;
select set_config('request.jwt.claims', '{\"sub\":\"$sub\",\"role\":\"authenticated\"}', true);
$1" 2>&1
}
# ask <sub> <scalar sql> — the last line of output, as that subject.
ask() { as "$1" "$2" | tail -1; }
# owner <scalar sql> — ground truth, read as the schema owner past every policy.
owner() { psql "$OWNER_URL" -tA --no-psqlrc -c "$1" 2>&1 | tail -1; }
# repair <sql> — undo whatever an exploit managed to do.
repair() { psql "$OWNER_URL" -q --no-psqlrc -c "$1" >/dev/null 2>&1; }

# expect <name> <actual> <wanted>
expect() {
  if [ "$2" = "$3" ]; then held "$1"; else breach "$1" "expected '$3', got '$2'"; fi
}
# attack <name> <sub> <attack sql> <state query> <safe state> [repair sql]
# The attack runs; the verdict comes from the state query, read as owner.
attack() {
  local name="$1" sub="$2" sql="$3" check="$4" safe="$5" fix="${6:-}"
  as "$sub" "$sql" >/dev/null 2>&1
  local got; got="$(owner "$check")"
  if [ "$got" = "$safe" ]; then held "$name"; else breach "$name" "state is now '$got', should be '$safe'"; fi
  [ -n "$fix" ] && repair "$fix"
  return 0
}

echo "── identity resolution ─────────────────────────────────────────────────"

expect "a token resolves to the application user" \
       "$(ask "$SUB_TAILOR" "select coalesce(app.current_user_id()::text,'null');")" "$U_TAILOR"
expect "and to that user's business" \
       "$(ask "$SUB_TAILOR" "select coalesce(app.current_business_id()::text,'null');")" "$BIZ_A"
expect "a token for an unknown subject resolves to nobody" \
       "$(ask "00000000-dead-0000-0000-000000000000" "select coalesce(app.current_user_id()::text,'null');")" "null"
expect "a token with no subject claim resolves to nobody" \
       "$(psql "$PROBE_URL" -tA --no-psqlrc -c "set role authenticated;
          select set_config('request.jwt.claims','{\"role\":\"authenticated\"}',true);
          select coalesce(app.current_user_id()::text,'null');" 2>&1 | tail -1)" "null"
expect "an empty subject claim resolves to nobody" \
       "$(ask "" "select coalesce(app.current_user_id()::text,'null');")" "null"
expect "a malformed subject claim resolves to nobody rather than raising" \
       "$(ask "not-a-uuid" "select coalesce(app.current_user_id()::text,'null');")" "null"
expect "an absent claims setting resolves to nobody" \
       "$(psql "$PROBE_URL" -tA --no-psqlrc -c "set role authenticated;
          select coalesce(app.current_user_id()::text,'null');" 2>&1 | tail -1)" "null"

echo
echo "── impersonation and session manipulation ──────────────────────────────"

expect "app.actor_id alongside a token changes nothing" \
       "$(ask "$SUB_TAILOR" "select set_config('app.actor_id','$U_OWNER',true);
                             select coalesce(app.current_user_id()::text,'null');")" "$U_TAILOR"
expect "discarding the token and naming an actor yields nobody" \
       "$(psql "$PROBE_URL" -tA --no-psqlrc -c "set role authenticated;
          select set_config('request.jwt.claims','',true);
          select set_config('app.actor_id','$U_OWNER',true);
          select coalesce(app.current_user_id()::text,'null');" 2>&1 | tail -1)" "null"
expect "an untrusted session is untrusted" \
       "$(ask "$SUB_TAILOR" "select app.session_is_trusted()::text;")" "false"

OUT="$(as "$SUB_TAILOR" "select app.set_context('$U_OWNER',null,null,null);")"
if echo "$OUT" | grep -qi 'permission denied'; then held "an API session cannot execute app.set_context"
else breach "an API session cannot execute app.set_context" "$(echo "$OUT"|tail -1)"; fi

expect "request context does not survive into the next transaction" \
       "$(psql "$PROBE_URL" -tA --no-psqlrc <<SQL 2>&1 | tail -1
set role authenticated;
begin;
select set_config('app.reason_code','probe',true);
commit;
select coalesce(nullif(current_setting('app.reason_code', true),''),'gone');
SQL
)" "gone"

echo
echo "── self-granting: permissions ──────────────────────────────────────────"

expect "the tailor starts without config.tax.manage" \
       "$(ask "$SUB_TAILOR" "select app.has_permission('config.tax.manage')::text;")" "false"

attack "the tailor cannot add a permission to their own role" "$SUB_TAILOR" \
  "insert into role_permission (business_id, role_id, permission_id) values ('$BIZ_A','$R_TAILOR','$P_TAXCFG');" \
  "select count(*)::text from role_permission where role_id='$R_TAILOR' and permission_id='$P_TAXCFG' and deleted_at is null;" \
  "0" \
  "delete from role_permission where role_id='$R_TAILOR' and permission_id='$P_TAXCFG';"

attack "nor invent a new permission" "$SUB_TAILOR" \
  "insert into permission (business_id, code, domain) values ('$BIZ_A','invented.superpower','identity');" \
  "select count(*)::text from permission where code='invented.superpower';" "0" \
  "delete from permission where code='invented.superpower';"

attack "nor create a role" "$SUB_TAILOR" \
  "insert into role (business_id, code, name) values ('$BIZ_A','pirate','Pirate');" \
  "select count(*)::text from role where code='pirate';" "0" \
  "delete from role where code='pirate';"

attack "nor grant themselves the owner role" "$SUB_TAILOR" \
  "insert into user_branch_role (business_id, user_id, branch_id, role_id) values ('$BIZ_A','$U_TAILOR','$BR_A1','$R_OWNER');" \
  "select count(*)::text from user_branch_role where user_id='$U_TAILOR' and role_id='$R_OWNER' and deleted_at is null;" \
  "0" \
  "delete from user_branch_role where user_id='$U_TAILOR' and role_id='$R_OWNER';"

attack "nor promote their existing grant to a higher role" "$SUB_TAILOR" \
  "update user_branch_role set role_id='$R_OWNER' where user_id='$U_TAILOR';" \
  "select role_id::text from user_branch_role where user_id='$U_TAILOR' and deleted_at is null limit 1;" \
  "$R_TAILOR" \
  "update user_branch_role set role_id='$R_TAILOR' where user_id='$U_TAILOR';"

expect "and after all of that still holds no tax permission" \
       "$(ask "$SUB_TAILOR" "select app.has_permission('config.tax.manage')::text;")" "false"

echo
echo "── self-granting: branches ─────────────────────────────────────────────"

expect "the tailor holds no grant for the second branch" \
       "$(ask "$SUB_TAILOR" "select app.has_branch('$BR_A2')::text;")" "false"

attack "and cannot grant themselves the branch they lack" "$SUB_TAILOR" \
  "insert into user_branch_role (business_id, user_id, branch_id, role_id) values ('$BIZ_A','$U_TAILOR','$BR_A2','$R_TAILOR');" \
  "select count(*)::text from user_branch_role where user_id='$U_TAILOR' and branch_id='$BR_A2' and deleted_at is null;" \
  "0" \
  "delete from user_branch_role where user_id='$U_TAILOR' and branch_id='$BR_A2';"

attack "a manager holding user.manage cannot extend themselves into a branch they do not hold" "$SUB_MGR" \
  "insert into user_branch_role (business_id, user_id, branch_id, role_id) values ('$BIZ_A','$U_MGR','$BR_A2','$R_MGR');" \
  "select count(*)::text from user_branch_role where user_id='$U_MGR' and branch_id='$BR_A2' and deleted_at is null;" \
  "0" \
  "delete from user_branch_role where user_id='$U_MGR' and branch_id='$BR_A2';"

attack "nor create a branch and walk into it" "$SUB_TAILOR" \
  "insert into branch (id, business_id, code, name) values ('aaaa0007-0000-0000-0000-0000000000ff','$BIZ_A','A3','Invented');" \
  "select count(*)::text from branch where code='A3';" "0" \
  "delete from branch where code='A3';"

echo
echo "── revocation and account state ────────────────────────────────────────"

repair "update user_branch_role set revoked_at = now() where user_id = '$U_TAILOR';"
expect "a revoked grant leaves the caller's branch list immediately" \
       "$(ask "$SUB_TAILOR" "select cardinality(app.current_branch_ids())::text;")" "0"
expect "and the caller loses the permissions that came with it" \
       "$(ask "$SUB_TAILOR" "select app.has_permission('order.create')::text;")" "false"

attack "a revoked user cannot un-revoke themselves" "$SUB_TAILOR" \
  "update user_branch_role set revoked_at = null where user_id = '$U_TAILOR';" \
  "select count(*)::text from user_branch_role where user_id='$U_TAILOR' and revoked_at is null and deleted_at is null;" \
  "0"
repair "update user_branch_role set revoked_at = null where user_id = '$U_TAILOR';"

repair "update app_user set status='suspended' where id='$U_TAILOR';"
expect "a suspended user resolves to nobody" \
       "$(ask "$SUB_TAILOR" "select coalesce(app.current_user_id()::text,'null');")" "null"
expect "and reaches no rows at all" \
       "$(ask "$SUB_TAILOR" "select count(*)::text from customer;")" "0"
repair "update app_user set status='active' where id='$U_TAILOR';"

repair "update app_user set deleted_at=now() where id='$U_TAILOR';"
expect "a soft-deleted user resolves to nobody" \
       "$(ask "$SUB_TAILOR" "select coalesce(app.current_user_id()::text,'null');")" "null"
repair "update app_user set deleted_at=null where id='$U_TAILOR';"

expect "and the same user works again once reinstated" \
       "$(ask "$SUB_TAILOR" "select coalesce(app.current_user_id()::text,'null');")" "$U_TAILOR"

echo
echo "── tampering with other people ─────────────────────────────────────────"

attack "the tailor cannot edit another user's record" "$SUB_TAILOR" \
  "update app_user set full_name='Renamed' where id='$U_OWNER';" \
  "select full_name from app_user where id='$U_OWNER';" "A owner" \
  "update app_user set full_name='A owner' where id='$U_OWNER';"

attack "nor revoke the owner's access" "$SUB_TAILOR" \
  "update user_branch_role set revoked_at=now() where user_id='$U_OWNER';" \
  "select count(*)::text from user_branch_role where user_id='$U_OWNER' and revoked_at is not null;" "0" \
  "update user_branch_role set revoked_at=null where user_id='$U_OWNER';"

attack "nor strip the owner's role of its permissions" "$SUB_TAILOR" \
  "delete from role_permission where role_id='$R_OWNER';" \
  "select count(*)::text from role_permission where role_id='$R_OWNER' and deleted_at is null;" "4"

attack "nor soft-delete the owner" "$SUB_TAILOR" \
  "update app_user set deleted_at=now() where id='$U_OWNER';" \
  "select count(*)::text from app_user where id='$U_OWNER' and deleted_at is not null;" "0" \
  "update app_user set deleted_at=null where id='$U_OWNER';"

if [ "$HAS_AUTH_COL" = "1" ]; then
  attack "nor point the owner's login at their own auth identity" "$SUB_TAILOR" \
    "update app_user set auth_user_id='$AUTH_TAILOR' where id='$U_OWNER';" \
    "select coalesce(auth_user_id::text,'null') from app_user where id='$U_OWNER';" "$AUTH_OWNER" \
    "update app_user set auth_user_id='$AUTH_OWNER' where id='$U_OWNER';"
  attack "nor claim a second auth identity for themselves" "$SUB_TAILOR" \
    "update app_user set auth_user_id='$AUTH_OWNER' where id='$U_TAILOR';" \
    "select coalesce(auth_user_id::text,'null') from app_user where id='$U_TAILOR';" "$AUTH_TAILOR" \
    "update app_user set auth_user_id='$AUTH_TAILOR' where id='$U_TAILOR';"
fi

echo
echo "── the PIN ─────────────────────────────────────────────────────────────"

if [ "$HAS_AUTH_COL" = "1" ]; then
  # After 0016 the hash lives in user_credential, which no application role
  # holds any privilege on at all.
  repair "insert into user_credential (business_id, user_id, pin_hash) values ('$BIZ_A','$U_OWNER','SECRET-HASH')
          on conflict (user_id, deleted_at) do update set pin_hash = 'SECRET-HASH';"

  OUT="$(as "$SUB_TAILOR" "select pin_hash from user_credential;")"
  if echo "$OUT" | grep -q 'SECRET-HASH'; then
    breach "a colleague cannot read another user's PIN hash" "read it back in full"
  else held "a colleague cannot read another user's PIN hash ${DIM}($(echo "$OUT"|tail -1|cut -c1-40))${RESET}"; fi

  attack "nor overwrite one" "$SUB_TAILOR" \
    "update user_credential set pin_hash='ATTACKER' where user_id='$U_OWNER';" \
    "select pin_hash from user_credential where user_id='$U_OWNER';" "SECRET-HASH"

  # A PIN is a lock over a session the device already holds. It must not, on
  # its own, make the caller into anybody.
  as "$SUB_TAILOR" "select app.set_pin('4321');" >/dev/null 2>&1
  R="$(ask "$SUB_TAILOR" "select app.verify_pin('$U_TAILOR','4321')::text;")"
  [ "$R" = "true" ] && held "a person can set and verify their own PIN" \
                    || breach "a person can set and verify their own PIN" "verify returned '$R'"

  R="$(ask "$SUB_TAILOR" "select app.verify_pin('$U_TAILOR','9999')::text;")"
  [ "$R" = "false" ] && held "a wrong PIN verifies false" || breach "a wrong PIN verifies false" "got '$R'"

  R="$(ask "$SUB_TAILOR" "select app.verify_pin('$U_TAILOR','4321'); select coalesce(app.current_user_id()::text,'null');")"
  [ "$R" = "$U_TAILOR" ] && held "and a correct PIN establishes no identity ${DIM}(the caller is still themselves)${RESET}" \
                         || breach "a correct PIN establishes no identity" "became '$R'"

  attack "the tailor cannot set the owner's PIN" "$SUB_TAILOR" \
    "select app.set_pin('1111','$U_OWNER');" \
    "select pin_hash from user_credential where user_id='$U_OWNER';" "SECRET-HASH"

  R="$(ask "$SUB_TAILOR" "select app.verify_pin('$U_B','4321')::text;")"
  [ "$R" = "false" ] && held "and cannot probe a PIN in another business" \
                     || breach "and cannot probe a PIN in another business" "got '$R'"
else
  repair "update app_user set pin_hash='SECRET-HASH' where id='$U_OWNER';"
  OUT="$(as "$SUB_TAILOR" "select coalesce(pin_hash,'null') from app_user where id='$U_OWNER';")"
  if echo "$OUT" | grep -q 'SECRET-HASH'; then
    breach "a colleague cannot read another user's PIN hash" "read it back in full"
  else held "a colleague cannot read another user's PIN hash"; fi

  attack "nor set another user's PIN" "$SUB_TAILOR" \
    "update app_user set pin_hash='ATTACKER' where id='$U_OWNER';" \
    "select pin_hash from app_user where id='$U_OWNER';" "SECRET-HASH"
fi

echo
echo "── cross-business ──────────────────────────────────────────────────────"

expect "A reads none of B's customers"           "$(ask "$SUB_TAILOR" "select count(*)::text from customer where business_id='$BIZ_B';")" "0"
expect "nor B's people"                          "$(ask "$SUB_TAILOR" "select count(*)::text from app_user where business_id='$BIZ_B';")" "0"
expect "nor B's permission catalogue"            "$(ask "$SUB_TAILOR" "select count(*)::text from permission where business_id='$BIZ_B';")" "0"
expect "nor B's branch/role grants"              "$(ask "$SUB_TAILOR" "select count(*)::text from user_branch_role where business_id='$BIZ_B';")" "0"

attack "and cannot attach one of B's permissions to a role of A's" "$SUB_TAILOR" \
  "insert into role_permission (business_id, role_id, permission_id) values ('$BIZ_A','$R_TAILOR','$P_B_TAXCFG');" \
  "select count(*)::text from role_permission where permission_id='$P_B_TAXCFG' and business_id='$BIZ_A';" "0" \
  "delete from role_permission where permission_id='$P_B_TAXCFG' and business_id='$BIZ_A';"

attack "nor grant one of B's users a role in A" "$SUB_TAILOR" \
  "insert into user_branch_role (business_id, user_id, branch_id, role_id) values ('$BIZ_A','$U_B','$BR_A1','$R_TAILOR');" \
  "select count(*)::text from user_branch_role where user_id='$U_B' and business_id='$BIZ_A';" "0" \
  "delete from user_branch_role where user_id='$U_B' and business_id='$BIZ_A';"

attack "nor move themselves into business B" "$SUB_TAILOR" \
  "update app_user set business_id='$BIZ_B' where id='$U_TAILOR';" \
  "select business_id::text from app_user where id='$U_TAILOR';" "$BIZ_A" \
  "update app_user set business_id='$BIZ_A' where id='$U_TAILOR';"

echo
echo "── shadowing and search_path ───────────────────────────────────────────"

expect "a temporary app_user cannot redirect the caller's tenant" \
  "$(psql "$PROBE_URL" -tA --no-psqlrc -c "set role authenticated;
     select set_config('request.jwt.claims','{\"sub\":\"$SUB_TAILOR\",\"role\":\"authenticated\"}',true);
     create temp table app_user (id uuid, business_id uuid, auth_user_id uuid, status text, deleted_at timestamptz);
     insert into pg_temp.app_user values ('$U_TAILOR','$BIZ_B','$SUB_TAILOR','active',null);
     select coalesce(app.current_business_id()::text,'null');" 2>&1 | tail -1)" "$BIZ_A"

expect "a temporary user_branch_role cannot invent a branch grant" \
  "$(psql "$PROBE_URL" -tA --no-psqlrc -c "set role authenticated;
     select set_config('request.jwt.claims','{\"sub\":\"$SUB_TAILOR\",\"role\":\"authenticated\"}',true);
     create temp table user_branch_role (user_id uuid, branch_id uuid, role_id uuid, revoked_at timestamptz, deleted_at timestamptz);
     insert into pg_temp.user_branch_role values ('$U_TAILOR','$BR_A2',null,null,null);
     select app.has_branch('$BR_A2')::text;" 2>&1 | tail -1)" "false"

expect "temporary permission tables cannot forge a permission" \
  "$(psql "$PROBE_URL" -tA --no-psqlrc -c "set role authenticated;
     select set_config('request.jwt.claims','{\"sub\":\"$SUB_TAILOR\",\"role\":\"authenticated\"}',true);
     create temp table role_permission (role_id uuid, permission_id uuid, deleted_at timestamptz);
     create temp table permission (id uuid, code text, deleted_at timestamptz);
     insert into pg_temp.permission values ('$P_TAXCFG','config.tax.manage',null);
     insert into pg_temp.role_permission values ('$R_TAILOR','$P_TAXCFG',null);
     select app.has_permission('config.tax.manage')::text;" 2>&1 | tail -1)" "false"

echo
echo "── anon ────────────────────────────────────────────────────────────────"

for T in app_user role permission role_permission user_branch_role business branch device; do
  OUT="$(psql "$PROBE_URL" -tA --no-psqlrc -c "set role anon; select count(*) from $T;" 2>&1)"
  if echo "$OUT" | grep -qi 'permission denied'; then held "anon is refused at $T"
  else breach "anon is refused at $T" "$(echo "$OUT" | tail -1)"; fi
done

echo
echo "── function exposure ───────────────────────────────────────────────────"

EXPOSED="$(owner "select coalesce(string_agg(p.proname,', ' order by p.proname),'(none)')
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='app' and (has_function_privilege('public',p.oid,'EXECUTE')
                          or has_function_privilege('anon',p.oid,'EXECUTE'));")"
expect "no app function is executable by PUBLIC or anon" "$EXPOSED" "(none)"

UNPINNED="$(owner "select coalesce(string_agg(p.proname,', ' order by p.proname),'(none)')
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='app' and p.prosecdef
    and (p.proconfig is null or not exists (select 1 from unnest(p.proconfig) c where c like 'search_path=%'));")"
expect "every SECURITY DEFINER function pins its search_path" "$UNPINNED" "(none)"

echo
if [ "$FAIL" -gt 0 ]; then
  printf '%s%d BREACHES%s, %d invariants held\n\n' "$RED" "$FAIL" "$RESET" "$PASS"; exit 1
fi
printf '%sHELD%s  %d invariants, no breach\n\n' "$GREEN" "$RESET" "$PASS"
