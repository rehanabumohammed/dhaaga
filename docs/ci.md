# Continuous integration — status and the local substitute

## What CI does

`.github/workflows/ci.yml` is the definition of "green". Against a clean
`postgres:16` service container it runs, in order:

0. `scripts/env_loader.py --selftest` — the .env parser, including the files
   Windows editors produce (byte-order mark, CRLF) and the precedence rule the
   harnesses depend on: a variable already in the environment always wins, or
   every scratch-database suite would silently test the developer's own
   database while reporting success.
1. `scripts/selftest_migrations.sh` — the runner's own guarantees, including the
   negative cases (edited migration, out-of-order migration, missing rollback).
2. `scripts/migrate.py up` — build the schema from empty.
3. `scripts/migrate.py verify` — checksums and rollback pairing intact.
4. `scripts/test.py` — the database test suite.
4b. `scripts/test_concurrency.sh` — the races the single-session suite cannot
   express: two sessions reversing one journal entry, two devices leasing the
   same document numbers. It builds and drops its own scratch database.
4c. `scripts/test_api_session.sh` — the checks that depend on `session_user`.
   The SQL suite connects as the schema owner and uses SET ROLE, so its session
   is trusted whichever role it switches to; this harness creates a real second
   login role shaped like PostgREST's `authenticator` and connects as it.
4d. `scripts/attack_identity.sh` — the WP-7 adversarial probe. Attacks identity
   and authorization from a real untrusted login role and judges every attempt
   by reading the resulting state back as the owner, because under row-level
   security a forbidden write frequently "succeeds" while changing nothing.
4e. `scripts/scan_hardcoded.py` — no rule-shaped literal in application code
   (AP-1, BR-21). Its own `--selftest` runs first, so a clean result means the
   scan works rather than that it looked nowhere.
5. `migrate.py reset` then `up` — prove teardown and rebuild.

## The limitation, stated plainly

**CI has never run.** Two reasons, both environmental:

* the repository has no remote yet, so no workflow has ever been triggered;
* the development environment cannot reach GitHub, so it cannot push one.

Additionally, `.github/workflows/ci.yml` is a protected path for the file bridge
between the development environment and the Product Owner's machine, so that one
file is delivered for manual placement rather than written automatically.

CI is kept in the repository regardless. It is not removed, weakened, bypassed
or disabled because it cannot currently execute (decision, 26 Aug 2026).

## The local substitute

Every CI step is run locally against PostgreSQL 16 — the same major version
Supabase Cloud runs — and its output is reported with the work package it
belongs to. The commands are identical to the workflow's:

```bash
python3 scripts/env_loader.py --selftest
scripts/selftest_migrations.sh
python3 scripts/migrate.py up
python3 scripts/migrate.py verify
python3 scripts/seed.py --verify
python3 scripts/test.py
bash scripts/test_concurrency.sh
bash scripts/test_api_session.sh
bash scripts/attack_identity.sh
python3 scripts/scan_hardcoded.py --selftest
python3 scripts/scan_hardcoded.py
python3 scripts/gen_schema_doc.py --check
python3 scripts/gen_cloud_check.py --check
python3 scripts/migrate.py reset && python3 scripts/migrate.py up
```

Two differences from a real CI run, and they matter:

* **A local run is not a clean-room run.** CI starts from an empty container; a
  local run starts from whatever state the developer's machine is in. The
  teardown-and-rebuild step exists to narrow that gap, not to close it.
* **A local run proves nothing about the workflow file itself.** Its YAML is
  validated, but the steps have never been executed by the runner.

## The rule

Local validation is reported as local validation. **No work package report
claims CI has passed until CI has actually run.** The first push will either
confirm the workflow or expose what it was missing, and that outcome is reported
either way.
