# ADR-0008 · Audit is captured by triggers, and three consequences of that

**Status** Accepted · P0 WP-4 · 26 Aug 2026

## Context
BR-13 requires that money and permission changes record who, what, when,
before, after and a reason. The capture can live in application code or in the
database.

## Decision
Database triggers. Application-side auditing is written once per code path and
forgotten on the second one; the log is then missing exactly the event somebody
needs six weeks later. A trigger cannot be forgotten, and it records a change
made from a SQL console as faithfully as one made from the app — which is the
case that matters most, because that is the change nobody meant to be seen.

Three consequences were decided deliberately rather than discovered later.

### 1. A no-op update writes nothing
`updated_at`, `updated_by` and `row_version` change on every write. If they
counted as changes, every touch would produce an audit row and the trail would
be noise. They are stored in before/after but excluded from `changed_fields`,
and an update that moves nothing else is not recorded at all.

### 2. Attribution degrades; it never blocks
`audit_event.device_id` is a foreign key, which is right — a row pointing at a
device that does not exist says nothing. But the trigger runs inside the
caller's transaction, so a client sending a stale device id would fail the audit
insert and fail the customer's order behind it.

Losing an attribution field is a data-quality problem. Refusing to take an order
at the counter is a business failure. The device is therefore resolved
defensively: attributed when known, null when not, never a reason to fail. A
test asserts that a *registered* device IS attributed, so the tolerance cannot
quietly become the normal case.

### 3. Reason enforcement applies to people, not to migrations
A migration, a restore or a seed has no actor to ask for a justification, and
blocking them would make the database unmaintainable. Reasons are therefore
enforced only when there is an actor. Those changes are still recorded, with
`source` of `console` or `system` — which is the point: they are reviewable
afterwards rather than invisible.

This is a real gap, stated plainly: someone with database credentials can change
data without giving a reason. They cannot do it without leaving a record.

## Consequences
* `app.set_context()` is how a server-side caller supplies actor, device and
  reason. It is transaction-scoped and cannot leak into the next request.
* The audit table carries a `BEFORE UPDATE OR DELETE` trigger that raises, so
  rows are immutable **to the table owner as well**. Policies and grants restrain
  an application caller; they do not restrain `postgres`. Removing this means
  dropping a trigger, which is a schema change and therefore visible.
* Which actions demand a reason is a table, not a constant (AP-1), narrowed to
  specific columns so a price override needs a reason and fixing a spelling
  does not.
* The watched-table list is explicit rather than "everything": auditing tables
  where nothing of consequence happens doubles write volume for no benefit. A
  coverage test asserts the list still contains every event BR-13 names.
