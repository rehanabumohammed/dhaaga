# ADR-0001 · Develop against a local PostgreSQL 16 matching Supabase

**Status** Accepted · P0 · 26 Aug 2026
**Decision by** RayHaan (hosting decision), implemented in WP-1

## Context
Hosting is Supabase Cloud in an Indian region. Supabase runs PostgreSQL with
row-level security, and its client libraries assume PostgREST conventions such
as `request.jwt.claims`. Building directly against the cloud project during P0
would make every schema experiment a shared, stateful operation and would tie
local test runs to network availability.

## Decision
Develop and test against a local PostgreSQL 16 instance using only extensions
available on Supabase (`pgcrypto`, `pg_trgm`, `btree_gist`), and reproduce the
Supabase session-context convention (`request.jwt.claims`) in the helper
functions. Migrations are proven locally, then applied to the cloud project.

## Consequences
* A migration proven locally is proven for production; there is no dialect gap.
* CI can run the full database suite against a plain `postgres:16` container.
* Supabase-specific surfaces that are not plain PostgreSQL — the `auth` schema,
  storage, edge functions — are **not** exercised locally. Those are integrated
  and tested against a real Supabase project during WP-7 and WP-10, and that
  gap is recorded rather than assumed away.
* `scripts/export_supabase.py` produces the CLI's expected layout so the cloud
  project is never hand-edited.
