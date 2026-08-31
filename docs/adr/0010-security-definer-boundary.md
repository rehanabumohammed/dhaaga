# ADR-0010 · A SECURITY DEFINER function must re-assert every boundary it bypasses

**Status** Accepted · WP-5 audit · 26 Aug 2026
**Severity of the defect that prompted it** Critical (tenant isolation bypass)

## What was found

The WP-5 audit reproduced three defects against the running database. None
required an architectural change — the design (tenant derived from the caller's
user row, isolation enforced by row-level security) was sound. The
implementation had holes that let a caller step around it.

### 1. Identity could be reassigned by the caller — critical

`app.current_user_id()` consulted the `app.actor_id` session variable **before**
the JWT, so that server-side jobs could act as a user. `app.set_context()`,
which sets that variable, was granted to `authenticated` so the client could
supply a device and a reason for the audit trail.

Each decision was defensible alone. Together:

```sql
-- as an authenticated user of business A
select app.set_context(actor_id => '<any user id in business B>');
select display_name from customer;   -- returns business B's customers
```

Reproduced end to end. This defeated the whole of WP-3: every policy in the
database trusts `app.current_business_id()`, which trusts `current_user_id()`.
It also meant audit rows could be attributed to another person.

**Why the WP-3 isolation suite missed it.** That suite asked "can this caller
reach another tenant's rows" and correctly answered no. It never asked "can this
caller *become* another user" — an authorisation test, where the gap was in
authentication. Both questions are now in the suite.

### 2. SECURITY DEFINER functions did not re-check the tenant — high

`app.post_entry()` and `app.reverse_journal_entry()` run as their owner, which
is necessary: the balance check must see every line of an entry, including lines
row-level security would hide. But that also means RLS does not apply *inside*
them, and neither re-checked the caller's tenant.

An authenticated user could post ledger entries into a branch they hold no grant
for, using nothing secret — a branch id is visible to everyone in the business.
Reproduced. Reversing another business's entry was also possible given its id;
that one required knowing a UUID, which is obscurity, not a control.

### 3. EXECUTE was granted to PUBLIC — defence in depth

PostgreSQL grants EXECUTE on new functions to PUBLIC. Not reachable by `anon`,
which holds no USAGE on the `app` schema, but one future grant would have made
every SECURITY DEFINER function anonymously callable.

## Decisions

1. **A verified token always wins.** `current_user_id()` returns the JWT subject
   whenever one is present. The session override applies only when there is no
   token at all — the server-side and console case it was written for. A REST
   caller always carries a token, so the override is unreachable from there.

2. **Identity and context are separate capabilities.** `app.set_context()` can
   name an actor and is now service-role only. Application users get
   `app.set_request_context()`, which sets a device and a reason and *cannot*
   name an identity. The separation is structural rather than a promise not to
   misuse the wider function.

3. **`app.assert_tenant_write()` is called by every SECURITY DEFINER function
   that accepts a caller-supplied business or branch.** A named, reusable check
   rather than something each function is trusted to remember.

4. **Ledger functions are not granted to `authenticated` at all.** The client
   never writes the ledger directly; P3 domain services will, and being
   SECURITY DEFINER themselves they call these as the owner. The boundary check
   inside them is therefore a second line of defence rather than the only one.

5. **EXECUTE is granted deliberately.** Every function in `app` has privileges
   revoked from PUBLIC, `anon` and `authenticated`, then granted back by name.
   Trigger functions get no grant: the system invokes them regardless, so
   leaving them ungranted removes a call path for nothing.

## The general rule

> A `SECURITY DEFINER` function is a hole in row-level security that we opened
> on purpose. It must re-assert, in its own body, every boundary it bypasses.

Enforced by assertions that check search_path pinning, PUBLIC and `anon`
executability, and the specific grants on the ledger functions — so a future
function that forgets is caught by the suite rather than by an incident.

## Addendum — the security regression gate (same day)

A second pass, run as a verification gate, found two more things. Both were
reachable only by reasoning about what had *not* been tested rather than
re-reading what had.

### 4. The token-clearing path

0013 made a verified token authoritative, which closed the reported bypass. It
left a residual: a caller able to run arbitrary SQL could discard its own token
and then set `app.actor_id`, falling through to the override.

```sql
select set_config('request.jwt.claims', '', true);
select set_config('app.actor_id', '<any user>', true);
-- identity is now that user
```

`pg_catalog.set_config` is executable by PUBLIC, so this needs no privilege
beyond a session. It is **not** reachable through PostgREST — a client gets
table CRUD and exposed RPC, and `set_config` is neither — but "not reachable
through the front door we happen to ship" is a weaker property than "not
reachable", and identity is the wrong place to accept the weaker one.

Closed in migration 0014: the override additionally requires a trusted session,
decided by `session_user`. That choice is deliberate — `current_user` becomes
the *function owner* inside a SECURITY DEFINER body and would report "trusted"
for every caller, which is precisely the mistake this check exists to avoid.
`session_user` survives both SET ROLE and definer nesting.

Proving it needed a new kind of test. The SQL suite connects as the schema owner
and uses SET ROLE, so its session is trusted whichever role it switches to — it
is structurally incapable of testing a session-trust boundary.
`scripts/test_api_session.sh` therefore creates a real second login role shaped
like PostgREST's `authenticator` (no ownership, NOINHERIT) and connects as it.

### 5. New functions are PUBLIC-executable, and that default cannot be revoked

While writing 0014 the suite failed on its own new function: PostgreSQL grants
EXECUTE on every new function to PUBLIC, so each migration that adds one
silently reopened what 0013 had just closed.

The obvious remedy does not work:

```sql
alter default privileges in schema app revoke execute on functions from public;
```

This is a **silent no-op**. `ALTER DEFAULT PRIVILEGES` can only remove
privileges a previous default GRANT added; it cannot revoke PostgreSQL's
built-in default. Verified: afterwards `pg_default_acl` holds no row, a new
function's `proacl` is NULL — meaning "built-in default applies" — and PUBLIC
can execute it. Adding a positive grant first does not help either; the stored
ACL still contains the PUBLIC entry.

So there is no database-level default that makes new functions fail closed. The
control is the assertion, which fails the build by name — and which is what
caught this. Every migration that creates a function must revoke explicitly.
That obligation is written into the migration rather than left as folklore.

A line that looks like protection but is a no-op is worse than no line at all,
so the ineffective statements were removed rather than left in place.

## Unresolved risk

A caller with genuine database credentials — the `postgres` role or the service
key — is outside all of this by construction. Their actions are recorded by the
audit trail with a source of `console` or `system`, which is the control that
applies to them. That is why the service key must never leave the owner's
machine.
