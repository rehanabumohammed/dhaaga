# ADR-0004 · Every table carries the same spine

**Status** Accepted · P0 · 26 Aug 2026

## Context
The architecture requires tenant isolation on every table (AP-7), soft deletion
everywhere (BR-19), optimistic concurrency for server-authoritative writes
(§5.2), audit attribution (BR-13) and client-generatable keys for offline-first
operation (§5).

## Decision
Every application table carries: `id uuid primary key`, `business_id`,
`created_at`, `created_by`, `updated_at`, `updated_by`, `deleted_at`,
`row_version`. Transactional tables additionally carry `branch_id`. Columns are
written out explicitly in each `CREATE TABLE` rather than injected by a helper,
so a reader sees the whole table; the trigger wiring is applied by
`app.attach_standard_triggers()` and the presence of the columns is enforced by
a convention test that fails the build if any table omits one.

## Consequences
* Policies, audit and sync all rely on a uniform shape, so they can be written
  once and applied generically.
* `business_id` is deliberately denormalised onto every table, including those
  where it could be derived through a join. This makes every policy a single
  predicate and gives a future partitioning key.
* The convention test is the enforcement. Without it the spine would rot within
  a phase.
