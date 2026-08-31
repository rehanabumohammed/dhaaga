# ADR-0011 · Configuration resolution, and the pg_temp shadowing class

**Status** Accepted · WP-6 · 29 Aug 2026
**Severity of the defect that prompted the search_path decision** High (in-tenant privilege escalation)

Migration `0015_config_resolvers.sql` turns the configuration registry created
in WP-2 into something the rest of the system can rely on. Five decisions in it
are material enough to record, and one is a security rule that now applies
beyond WP-6.

---

## 1. `search_path` is pinned on every function that names a relation, not only on SECURITY DEFINER ones

ADR-0010 established that a SECURITY DEFINER function must pin its
`search_path`. WP-6 found that the rule was drawn too narrowly.

PostgreSQL searches the session's temporary schema **first** — ahead of
`pg_catalog` — whenever `pg_temp` is not named explicitly in `search_path`. A
function that refers to a table without a schema qualifier can therefore be
pointed at a table of the caller's own making, regardless of whether it is
DEFINER or INVOKER.

The first draft of `app.enforce_config_permission()` — the trigger that decides
whether a caller may change a business rule — was SECURITY INVOKER with no
pinned path. Reproduced against the running database:

```sql
-- as a user holding no configuration permission
create temp table config_setting (id uuid, required_permission text);
insert into config_version (business_id, setting_id, value) values (…);
-- INSERT 0 1
```

The trigger looked up the required permission in the caller's empty temporary
table, found nothing, concluded that no permission was required, and let the
write through. Not a cross-tenant break — row-level security still confined the
write to the caller's own business — but a complete defeat of the control that
separates a tailor from an owner, which is the whole point of the trigger.

**Decision.** Every function in the `app` schema that names a relation pins
`search_path = public, pg_temp`, whatever its security mode. `pg_temp` is named
**last**, which is what removes it from the front of the search order.

The regression is asserted twice: once in `db/tests/0015_config.sql` as the
schema owner, and once in `scripts/test_api_session.sh` from a real untrusted
login role shaped like PostgREST's `authenticator`, because the owner's session
is not the session an attacker has. `db/verify/cloud_isolation.sql` carries the
same check so it can be re-run against the deployed project.

An audit of the pre-existing functions found no other instance: every SECURITY
DEFINER function was already pinned, and the unpinned INVOKER functions
(`app.touch_row`, `app.ledger_immutable`, `app.audit_immutable`, the session
readers) name no relations. The exposure was confined to WP-6's own additions.

---

## 2. `app.config_value()` is SECURITY INVOKER, deliberately

Every other resolver-adjacent function is DEFINER. The value resolver is not.

Under row-level security the caller can already read their own business's
configuration and nothing else, so the policies that exist enforce the boundary
without help. Making the resolver DEFINER would *remove* that enforcement and
require re-implementing it inside the function — more code, guarding the same
line, with a new way to get it wrong. A caller passing another business's id
would get that business's settings.

The test suite asserts the consequence directly: acting as `authenticated`,
`app.config_int('test.buffer_days', <business B's id>)` returns null rather than
B's value.

---

## 3. A read across the tenant boundary is a boundary crossing

`app.validation_status()` reads `validation_signoff` past row-level security,
because it is DEFINER, and it accepted a caller-supplied business id. In the
first draft any authenticated user could ask whether a competitor's books were
signed off:

```sql
select app.validation_status('tax', '<another business id>');   -- 'validated'
```

Three words of information, not a data breach — but ADR-0010's rule makes no
distinction between reading and writing, and neither should the code. The fix
adds `app.assert_tenant_read(uuid)` as the read counterpart of
`app.assert_tenant_write(uuid, uuid)`, and both `validation_status` and
`config_hash` call it.

**Decision.** The ADR-0010 rule reads: *a SECURITY DEFINER function must
re-assert every boundary it bypasses, whether it reads or writes.*

---

## 4. Validation status is derived, never stored

Whether a CA sign-off still covers the configuration is computed by comparing
the fingerprint stored with the sign-off against a fingerprint of the
configuration as it stands now. It is not a flag that something has to remember
to clear.

The alternative — a `is_valid` column invalidated by triggers on every table in
scope — has a failure mode this one does not: the day someone adds a setting to
the CA scope and forgets the trigger, the system reports a sign-off that covers
a configuration the CA never saw. That failure is silent and it is exactly the
failure BR-22 exists to prevent. A derived answer cannot drift.

The cost is that `app.validation_status()` is not free. It is called on invoice
insert and by the client for its banner, neither of which is a hot path.

## 4a. A domain with no defined scope is refused, not approximated

`validation_signoff.domain` permits `tax`, `accounting` and `payroll`. Only
`tax` has a defined fingerprint scope in V1. Rather than fingerprint a payroll
sign-off with the tax scope — recording an approval that describes something
the CA did not look at — `app.config_hash()` raises `feature_not_supported` for
any other domain, and `app.record_validation_signoff()` inherits the refusal.

A loud gap is better than a quiet lie about what was approved.

---

## 5. History is written before it is needed, not after

`app.set_config_value()` closes the previous version rather than replacing it,
so a document issued last year still resolves the rule that was in force when
it was issued (BR-15). Three cases turned out to need explicit handling, each
found by a test that failed first:

**The first change to a setting.** A setting seeded with a `current_value` and
no version rows has no history at all. Changing it overwrites `current_value`,
and a past-date lookup — which falls through to `current_value` when no version
covers the date — then answers the past with the *new* value. BR-15 appeared to
hold and did not. `set_config_value` now backfills the prior value as a version
covering `(-infinity, effective_from)` on the first change.

**A change made while a later one is scheduled.** A new value inserted with an
open-ended window collides with an already-scheduled future change under the
no-overlap constraint. The new value now ends where the scheduled one begins:
setting a rate today does not quietly cancel next quarter's.

**Two changes in one transaction.** `now()` does not advance inside a
transaction, so a second change to the same key asks for a zero-width window
and is refused by the exclusion constraint — an error with no relation to what
the caller did wrong. A change landing on exactly the same instant now corrects
the first rather than creating an unrepresentable state.

`current_value` is a cache of "the value in force now" and is updated only when
the new version's window actually contains `now()`.

---

## 6. The watermark is decided at issue and left alone

`app.set_invoice_watermark()` fires BEFORE INSERT, and on UPDATE only when
`doc_type` changes. An issued document does not change its mind: a sign-off
going stale next year must not retroactively mark last year's invoice as a
draft. The exception is relabelling — an estimate becoming a tax invoice starts
making the claim that needs validating, so the watermark is re-evaluated. The
first draft fired on INSERT only, which left relabelling as a way to produce an
unwatermarked tax invoice under a stale sign-off.

---

## 7. The hard-coded value scan

`scripts/scan_hardcoded.py` looks for rule-shaped literals in application code —
a numeric or quoted constant assigned to or compared against an identifier
named like a business rule. AP-1 and BR-21 make such a literal a defect,
because the owner cannot reach it and the CA sign-off cannot cover it.

It is a heuristic, so it is built to be checkable rather than believed:
`--selftest` plants known violations in a temporary tree and fails if the scan
misses them; a run that reads zero files reports FAILED rather than PASSED; and
an exception is declared with a `dhaaga:allow-literal <reason>` comment on or
above the line, so every exception appears in the diff that introduces it.

The registry itself (`0004_configuration.sql`), the seed and the test suite are
excluded by path — literals are what they are for.

Today it reads 34 files and finds nothing. The Dart directories are listed in
its roots before they exist, so it is already watching when WP-8 starts writing
into them.
