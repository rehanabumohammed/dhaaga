# ADR-0003 · Internal machinery lives in an `app` schema

**Status** Accepted · P0 · 26 Aug 2026

## Context
Supabase exposes the `public` schema through PostgREST. Anything created there
is potentially reachable by a client with a valid token, subject to row-level
security. Session helpers, trigger functions and table conventions are internal
machinery that no client should call.

## Decision
Application tables live in `public` and are exposed deliberately. All internal
functions, domains and conventions live in a separate `app` schema that is not
exposed. Migration bookkeeping lives in `dhaaga_meta`.

## Consequences
* The exposed API surface is exactly the set of tables and views intended.
* A future public API or customer portal inherits the same boundary.
* Helper functions must be `security definer` where a policy depends on them
  reading a table the caller cannot see — each such case is justified in the
  migration that creates it.
