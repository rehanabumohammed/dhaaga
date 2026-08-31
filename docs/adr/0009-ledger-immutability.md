# ADR-0009 · How the ledger is made immutable and self-balancing

**Status** Accepted · P0 WP-5 · 26 Aug 2026

## Context
BR-04 says posted financial entries are never modified or deleted and that
corrections are reversals. That is a claim about what is *possible*, not about
what the application chooses to do — so it has to be enforced where the
application cannot reach around it.

## Decisions

### 1. The balance check is deferred to commit
An entry is written, then its lines. An immediate check would fail on the first
line of every correct entry ever written. A `DEFERRABLE INITIALLY DEFERRED`
constraint trigger evaluates the rule when the transaction ends, which is what
lets it be absolute rather than approximately enforced.

It is `SECURITY DEFINER` so it sees every line of the entry. Under row-level
security a caller might see only some of them, and a balance check that cannot
see the whole entry is not a balance check.

### 2. Posting functions declare their own deferral
`SET CONSTRAINTS` is transaction-wide and sticky. Any earlier statement that set
constraints immediate would break every subsequent posting, failing between the
entry and its lines — with an error about missing lines that points nowhere near
the cause.

This was found by a test, not by reasoning: forcing the check in one assertion
broke an unrelated posting later in the same file. `app.post_entry()` and
`app.reverse_journal_entry()` therefore set constraints deferred themselves, so
a correct posting cannot be broken by unrelated session state.

### 3. Immutability is a trigger, not only a grant
Revoking UPDATE and DELETE stops an application caller. It does not stop
`postgres`, and production databases get connected to. A `BEFORE UPDATE OR
DELETE` trigger on `journal_entry` and `journal_line` raises for everyone.
Undoing it means dropping a trigger, which is a schema change and therefore
reviewable — unlike a quiet `UPDATE`.

Soft deletion is impossible on these tables too, deliberately: a ledger row that
can be hidden from reports is a ledger row that can be hidden.

### 4. An entry can be reversed exactly once
A unique index on `reversal_of_id` enforces it. Without that, a retried request
or a double click produces two mirrored entries and the books drift by the
amount of the original — silently, because both look correct in isolation.

A reversal cannot itself be reversed. Correcting a correction means posting a
fresh entry, which keeps the chain readable instead of producing a stack of
mutual cancellations nobody can follow.

### 5. A locked period refuses postings; a missing period does not
Posting into a locked period raises. Posting into a date with *no* period
defined is allowed, with a null period that is picked up when the period is
created. Refusing to record a sale because a bookkeeping period had not been set
up would stop the shop for an administrative reason, which is the wrong trade.

### 6. `security_invoker` on every view
Found while adding the trial balance. A view runs with its **owner's** rights by
default, so a view over protected tables is a hole straight past every policy
beneath it — and the table-coverage assertions cannot see it, because a view is
not a table.

`ledger_trial_balance` sets `security_invoker = true`, and the isolation suite
now asserts that *every* view in the schema does. The check was verified by
creating a leaky view deliberately and watching the suite name it.

## Consequences
* Correcting a posting is `app.reverse_journal_entry()`, and both entries remain
  visible forever.
* The trial balance nets to zero by construction; a test asserts it.
* The remaining way to alter the ledger is to drop a trigger in a migration,
  which is visible in version control and in the migration history.
