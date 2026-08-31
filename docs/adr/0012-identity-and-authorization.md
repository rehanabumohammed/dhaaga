# ADR-0012 · Identity, and why authorization state is not ordinary data

**Status** Accepted · WP-7 · 29 Aug 2026
**Severity of the defects that prompted it** Critical (in-tenant privilege escalation, reproduced)

WP-3 built the tenant boundary and proved it holds. WP-7 found that the
boundary *inside* the tenant did not exist at all.

Eighteen attacks were reproduced against the running database before a line of
migration 0016 was written. The worst of them is one statement long:

```sql
-- as a tailor, whose role grants production.own_jobs and nothing else
insert into role_permission (business_id, role_id, permission_id)
select business_id, '<my own role id>', id
  from permission where code = 'config.tax.manage';
-- INSERT 0 1
```

That is the whole of it. Every permission check in the system asks
`app.has_permission(code)`, which reads `role_permission`, which was an ordinary
table with an ordinary tenant policy and an ordinary `GRANT INSERT ... TO
authenticated`. The WP-6 configuration trigger, the books surface, the wage
ledger — all of it was gated on a table the person being gated could write.

---

## 1. The four things that were one thing

The model conflated facts that behave differently and fail differently. WP-7
separates them, and the separation is the reason most of the rest follows:

| | fact | where it lives | who may change it |
|---|---|---|---|
| authentication | this person proved who they are | Supabase Auth, `app_user.auth_user_id` | a trusted server session only |
| application user | which person that is | `app_user.id` | someone holding `user.manage` |
| tenancy | which business they belong to | `app_user.business_id` | nobody, from inside the app |
| authorization | what they may do | `user_branch_role` → `role` → `role_permission` | someone holding `user.manage` / `role.manage`, never themselves |

### `app_user.id` is no longer the auth subject

Migration 0003 documented `app_user.id` as "matches the Supabase auth user id".
Nothing enforced it, the seed contradicted it, and it fused the authenticator
with the application's own primary key. Three consequences, all real:

* a staff member who changes phone number gets a new Supabase Auth user, which
  under that model means rewriting every foreign key that points at them;
* there was no way to record someone who is paid and assigned work but never
  logs in — and a tailoring shop is full of them. Two of the five seeded staff
  have no phone number, so no OTP can reach them;
* nothing distinguished "the token said X" from "X is a person here", so a
  token for a deleted, suspended or entirely unknown subject resolved to a
  usable identity. Suspending an account revoked nothing.

`auth_user_id` is now a separate nullable column with a partial unique index:
one auth identity resolves to at most one person, and a person may have none.
There is deliberately **no foreign key to `auth.users`** — that schema exists on
Supabase and not in the local PostgreSQL the migrations are proven against, and
a constraint that only applies in one of the two places is a constraint that has
not been tested.

`app.current_identity()` resolves the subject to an **active, undeleted**
`app_user` row. That single predicate is what makes account revocation
immediate: there is no session to expire, because there is no session — every
statement re-resolves.

---

## 2. Enforcement is on the tables, not in setter functions

The alternative was a set of RPCs — `grant_branch_role`, `set_role_permissions`
and so on — with the tables closed to `authenticated` entirely.

Rejected, for the reason WP-6 already recorded: *a check that lives in one
function is a check the second caller skips.* PostgREST exposes these tables;
a future domain service, a bulk import or a console session with a user context
all write to them; and AP-5 says enforcement belongs below the application. Six
BEFORE-row triggers do the work instead, and they bind every path.

Two operations get functions anyway, because neither is expressible as a row
rule: hashing and verifying a PIN, and linking an authentication identity.

### The rules, as the triggers apply them

0. **No user context** — a migration, seed or restore — stands aside. Recorded
   by the audit trail with source `system` or `console`, not silently permitted.
1. **Nobody changes their own authorization.** Not by inserting a grant, not by
   editing one, not by clearing the `revoked_at` that took it away, not by
   suspending themselves out of an investigation.
2. **A grant may only be made into a branch the granter holds.** A manager
   covering one outlet cannot hand out access to another, and cannot reach into
   one by retargeting a grant that already points elsewhere.
3. **The named administrative permission is required** — `user.manage` for
   people and grants, `role.manage` for what a role contains, `branch.manage`
   and `business.manage` for tenancy structure. Administration is not one
   permission: holding `user.manage` does not carry `role.manage`.
4. **Attribution is recorded, not claimed.** `granted_by` and `revoked_by` are
   set by the trigger from `app.current_user_id()`, so a caller cannot supply
   somebody else's name for their own act.

### Two rules that close the loop

**A permission may not be added to a role the caller holds.** Without it, every
other rule is decoration: you cannot grant yourself a role, but you can add any
permission to the role you already have, which is the same thing with an extra
step. Removals stay open — giving up authority needs no protection. The
consequence is deliberate: the owner cannot extend the owner role from inside
the app. New permissions arrive with a migration.

**The permission catalogue is product vocabulary, not tenant data.** A business
composes roles out of it; it does not extend it. A tenant who can add
`invented.superpower` can also write the code that checks for it.

### Where that leaves provisioning

Linking an auth identity is the step that turns a row into someone who can log
in, so it is reserved to a trusted session (`app.link_auth_identity`, service
role only). This closes the last escalation chain: an owner may create a role
with every permission and a person to hold it, but cannot make that person
loggable-in-as, and cannot grant it to themselves.

---

## 3. The PIN is a lock, not an authentication mechanism

`app_user.pin_hash` was a column every colleague could `SELECT`. A hash anyone
can take away is a hash anyone can attack offline, and a four-digit PIN has ten
thousand values.

A column-level `REVOKE SELECT` was rejected: it makes `select *` fail for every
ordinary read, so the client breaks and someone grants it back. The hash moved
to `user_credential`, a table with **no privilege granted to any application
role** — not a narrower grant, none — plus row-level security and a
`using (false)` policy so the two cannot drift into disagreeing.

What the PIN is for: a counter assistant hands the tablet to a colleague. The
device already holds that colleague's Supabase session; the PIN unlocks it.

What it is not: `app.verify_pin` returns a boolean and nothing else. A correct
PIN establishes no identity in this database — asserted directly, by calling it
and then checking that `current_user_id()` has not moved. Minting credentials
here would duplicate Supabase Auth, which this system deliberately does not do.

Two details that are not decoration: five wrong attempts lock the PIN for
fifteen minutes (asserted, including that two *concurrent* wrong attempts both
count, so the lockout cannot be outrun by opening a second connection); and a
target in another business answers exactly as a target that does not exist,
because a refusal there would make the function an enumeration oracle.

---

## 4. Cross-business integrity, enforced relationally

`role_permission(role_id, permission_id)` had two single-column foreign keys, so
a role of business A could be bound to a permission of business B. Reproduced.
So could a person of B being granted a role in A.

Row-level security limits what an attacker can *see*, which makes this hard to
exploit from a client and does nothing to stop a service path or a migration.
Composite keys make the tenant part of the reference:

```sql
alter table role_permission
    add constraint role_permission_permission_same_business
        foreign key (business_id, permission_id) references permission (business_id, id);
```

The refusals are asserted with **no caller at all** — the migration path, where
every trigger stands aside — so the evidence is that the schema refuses, not
that a policy happened to be in the way.

---

## 5. Things found while fixing, worth naming

**`SECURITY DEFINER` does not bypass the `EXECUTE` privilege check.** The first
draft made `app.current_user_id()` an INVOKER wrapper around DEFINER
`app.current_identity()`, which is withheld from application roles because it
returns a whole person past row-level security. Every authenticated call failed
with `permission denied for function current_identity`. The wrappers are DEFINER
now — not for the read, which was already fine, but for the privilege check.
The same bit them again with `app.assert_can_administer`, which is called from
INVOKER triggers and therefore has to be callable by the caller whose write is
being checked. It is granted, and it is safe: it discloses nothing beyond
`app.has_permission`, which callers already have.

**A security harness that greps for `ERROR` measures nothing.** Under row-level
security a forbidden `UPDATE` routinely "succeeds" while matching zero rows, and
a real exploit that trips a check constraint raises. The first version of
`scripts/attack_identity.sh` reported eighteen breaches, of which four were
artefacts and three were contamination from an earlier exploit that had actually
worked. Rewritten so that every verdict is decided by reading the resulting
state back as the owner, and so that damage is repaired between attacks. This
is now the third time in this project that the test harness was the buggiest
code in the change.

**Fixtures need an identity of their own.** Since WP-7 an administrative write
demands a caller who holds the permission, so a test fixture left carrying the
previous case's token is refused — correctly, and at a line with nothing to do
with what is being tested. `dhaaga_test.as_nobody()` exists for that, and test
fixtures now derive an auth id distinct from the app_user id so a resolver that
confused the two would fail rather than pass by coincidence.

---

## 6. What WP-7 does not do

* **No admin surface.** There are no screens; the rules are in the database and
  WP-11 onward will call them. `docs/schema.md` and this ADR are the contract.
* **No login flow.** Supabase Auth issues tokens; nothing here changes that.
  Provisioning — creating the auth user and calling `link_auth_identity` — is a
  trusted server path that does not exist yet and must exist before the pilot.
* **No delegated administration beyond the branch.** Authority is per branch,
  which is the right grain for a shop. Regional scopes are not built.
* **No password, no session table, no token minting.** Deliberately.
