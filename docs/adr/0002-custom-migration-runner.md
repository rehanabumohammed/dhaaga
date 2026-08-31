# ADR-0002 · A dependency-free migration runner

**Status** Accepted · P0 · 26 Aug 2026

## Context
P0 needs migrations with rollback, integrity guarantees and CI execution.
Candidates: the Supabase CLI alone, a third-party tool (Flyway, sqitch,
Liquibase, dbmate), or a small purpose-built runner.

The Supabase CLI has no down-migrations and expects timestamped filenames. The
third-party tools each add a runtime dependency (JVM, Perl, Go binary) to every
environment including CI, in exchange for features this project does not need.

## Decision
A ~250-line Python runner over `psql`, with:
* checksums, so an applied migration that is later edited is refused;
* strict version ordering, so two branches cannot interleave history silently;
* mandatory paired rollback scripts, checked at plan time;
* one transaction per migration unless explicitly opted out.

## Consequences
* No build dependency beyond Python 3 and `psql`, both present in CI.
* The exact SQL applied is the SQL in version control — no generated DDL.
* We own the runner. It is covered by `scripts/selftest_migrations.sh`, which
  proves each guarantee including the negative cases.
* Rollback scripts must be written and kept correct by hand. In production the
  recovery strategy remains forward-fix plus point-in-time restore; rollback is
  a development and CI facility, and the ADR says so to avoid false confidence.
