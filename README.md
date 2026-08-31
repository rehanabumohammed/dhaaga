# Dhaaga

**The Operating System for the Modern Tailoring Business.**

Customers and
measurements, garment-level production, capacity-based promise dates, an
append-only financial ledger, and offline-first operation at the counter —
across one branch today and many later.

The architecture is specified in the blueprint (v0.3, final). This repository
implements it phase by phase. **Nothing here is a feature until its work package
has passed its gate.**

## Current state

| Phase | Work package | Status |
|-------|--------------|--------|
| P0 | WP-1 Environments and pipeline | complete |
| P0 | WP-2 Schema v1 | complete — 88 tables, 152 assertions |
| P0 | WP-3 Tenancy, RLS, isolation suite | complete — 88 tables protected |
| P0 | WP-4 Audit framework | complete — trigger-based, 25 assertions |
| P0 | WP-5 Ledger core and immutability | complete — audited, 3 defects fixed |
| P0 | WP-6 Configuration resolvers | complete — 72 assertions, 4 defects fixed |
| P0 | WP-7 Identity, roles and permissions | complete — 87 assertions, 8 defects fixed |
| P0 | WP-8 … WP-12 | not started |

All six schema clusters complete: tenancy/identity/audit · configuration,
localisation and tax · customers, households and measurements · orders,
production and capacity · finance · inventory and customer material.

`docs/schema.md` is generated from the live database by
`scripts/gen_schema_doc.py`; CI fails if the committed copy is stale.

## Continuous integration

`.github/workflows/ci.yml` is the authority on what must pass. It runs the
migration runner self-test, builds the schema from empty, verifies migration
integrity, runs the database test suite, and proves teardown and rebuild.

**It has not yet executed.** This repository has no remote, and the development
environment cannot reach GitHub. Until a first push, every CI step is instead
run locally against PostgreSQL 16 and its output reported with the work package.
Local validation is evidence; it is not a passing CI run, and no work package
report will claim CI has passed until CI has actually run. See `docs/ci.md`.

## Layout

```
lib/  android/  ios/  web/ …   the Flutter application
db/migrations/                 forward migrations, NNNN_lower_snake_case.sql
db/rollback/                   paired rollback scripts, one per migration
db/seed/                       seed data for a development business
db/tests/                      SQL tests; _helpers.sql holds the assertions
docs/adr/                      one architecture decision record per decision
scripts/                       migration runner, test runner, self-tests
.github/workflows/             CI
```

The Flutter app and the database live in one repository on purpose: a schema
change and the client change that depends on it belong in the same commit.

## Working with the database

```bash
cp .env.example .env               # PowerShell: Copy-Item .env.example .env
scripts/db_local.sh start          # local PostgreSQL 16 (Supabase's version)
python3 scripts/env_loader.py --selftest   # prove .env parsing, including Windows files
python3 scripts/migrate.py up      # build the schema
python3 scripts/seed.py --verify   # load development seed, prove idempotency
python3 scripts/test.py            # run the database test suite
python3 scripts/gen_schema_doc.py  # regenerate docs/schema.md
scripts/selftest_migrations.sh     # prove the runner's own guarantees
python3 scripts/scan_hardcoded.py  # no business rule literal in application code
scripts/attack_identity.sh         # attack the identity model from an untrusted session
```

On Windows these work in PowerShell as they are, with `python` in place of
`python3`. There is nothing to source: every script loads `.env` itself, and
each one prints the database it is about to touch (host and name only, never
credentials) so a stray `$env:DHAAGA_DB_URL` cannot send a command somewhere
unintended without saying so. The bash harnesses still need WSL or Git Bash.

## Rules enforced by tests, not by convention

* Applied migrations are immutable — to change something, write a new one.
* Every migration has a rollback script; the runner refuses one that does not.
* Every table carries the standard spine (ADR-0004).
* No naive timestamps and no floating-point columns anywhere.
* Posted financial entries are never updated or deleted (BR-04).
* Branch and business isolation is enforced in the database and proven by a
  suite that tries to breach it (WP-3).
* No user-visible string is hard-coded; English in V1, Hindi architecture from
  P0, Urdu addable later.
* No business rule an owner should control is hard-coded (AP-1, BR-21).
* Nobody can grant themselves a permission, a role or a branch (WP-7).
* Authentication, application identity, tenancy and authorization are four
  separate facts, and no client-supplied value can establish any of them.
* Tax and accounting configuration carries a recorded CA sign-off before
  production use (BR-22).

## Branch strategy

* `main` — always green: migrations apply from empty, all tests pass.
* `phase/p0-wp-<n>-<slug>` — one branch per work package, merged at its gate.
