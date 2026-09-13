# ADR-0018 · Commercial vocabulary is classified by business decision; the scanner only enforces it

**Status** Accepted · P0 · WP-9 · 13 Sep 2026
**Business approval** A18-BDR-001 (`docs/decisions/A18-BDR-001.md`) — Business Owner
**Decision by** Business Owner for the policy; architecture per the A18 decision-lock gates

## Context

`README` has asserted since WP-1 that no user-visible string is hard-coded, and
ADR-0014 built the catalogue half of that. Neither says anything about *which
words* belong in front of shop-floor staff. `docs/staff-glossary.md` sets
synonym discipline and tone — use **Branch**, not *outlet*; never *Please wait* —
and WP-9's test list requires a staff-vocabulary check that fails on an
accounting word. Nothing enforced it, and the glossary contains no accounting
lexicon to enforce.

The obvious shape — an accounting denylist — is wrong, and getting that wrong
would have been expensive. Dhaaga runs a real double-entry ledger. `debit` is a
column name in `journal_line`, a CHECK value in `account.normal_balance`, and a
column in `ledger_trial_balance`. The seeded roles include an **Accountant**.
The word is correct in half the system. What is wrong is a tailor at a counter
being shown it.

So the thing being built is not a denylist. It is a **classification** —
Dhaaga's Commercial & Business Administration Vocabulary Classification — of
which a staff-facing restriction policy is one enforcement view.

## Decisions

### 1. Six things stay separate, and none of them implies another

    vocabulary knowledge  ≠  staff-facing visibility  ≠  data access
    ≠  business decision authority  ≠  approval authority  ≠  accounting treatment

Dhaaga must *know* commercial and accounting vocabulary; that is business
knowledge. Restricting a word from staff-facing UI is a separate policy about
audience. Neither has anything to do with who may read ledger data — that is
row-level security, and ADR-0009 §6 already explains why it must not be
reachable around. **A vocabulary classification never grants, implies or
withholds data access.**

Accounting is one domain within the classification, not the classification
itself. An accounting term is **not** automatically forbidden.

### 2. Business decision → approved policy → technical enforcement → verification

    A18-BDR-001            policy/a18_vocabulary_policy.json
    (business decision)  → (machine-checkable policy)
                         → scripts/scan_vocabulary.py (enforcement)
                         → self-test + CI (verification evidence)

The direction is one-way. **A pull request, a commit, a CI result, an
engineering recommendation and this repository's own state are not business
approval.** The registry validator refuses to run a policy whose
`bdr_reference` does not resolve to a real, non-empty, self-identifying
Business Decision Record.

That refusal is not theoretical. An earlier implementation attempt was blocked
because `docs/decisions/A18-BDR-001.md` existed at its path and was zero bytes.
Existence is not evidence, so the invariant checks content, not presence.

### 3. The registry holds approved policy only, and is deliberately non-exhaustive

`policy/a18_vocabulary_policy.json` contains decisions that have been made. A
term that is absent is **UNRESOLVED** — no business decision exists for it —
and absence is how that state is represented. There is no `unresolved` value to
write, so an unapproved proposal cannot sit in the enforcement artifact looking
like policy.

The registry is **not** a vocabulary of Dhaaga and **not** a list of every
candidate term that analysis surfaced. Classifying the whole commercial
vocabulary before shipping was explicitly rejected: it would force dozens of
business decisions nobody needs yet.

### 4. Three policy fields, and enforcement is derived from them

    decision_status   approved | deferred
    audience_policy   staff-restricted | staff-allowed
    reason            mandatory; derived from the BDR's business rationale

    enforcement = (decision_status = approved) AND (audience_policy = staff-restricted)

**Enforcement is never stored.** A stored flag can contradict the decision it
claims to represent; a derived one cannot. `deferred + enforced` and
`staff-allowed + enforced` are therefore not merely invalid — they are
unrepresentable, and no validator rule is needed to catch them. The validator
rejects any row carrying an unrecognised field, so a stored `enforced` cannot
be reintroduced quietly.

Alongside the three policy fields a row carries `term` (its identity) and
`bdr_reference` (its evidence). Whether a term matches as a word or a phrase is
**derived from the term itself** — whitespace means phrase — rather than
configured, so there is one less field that can disagree with reality.

`reason` is normalised for technical documentation from the approving BDR's
business rationale. It may not introduce a rationale the BDR does not carry.

### 5. V1 restricts exactly one term

    debit — approved · staff-restricted · A18-BDR-001

Scope: **English staff-facing application message values within the A18 V1
scanner scope.** A18-BDR-001 states, and this ADR repeats because it is the
point most likely to be misread: the decision *"does not prohibit the term from
internal, administrative, technical, accounting, database, or other
non-staff-facing contexts."*

One term is not a placeholder for a larger list. It is the whole approved
policy until a business decision adds to it.

### 6. Staff-facing scope is declared, evidenced, and fail-safe

A catalogue key is staff-facing **unless** it carries a declared non-staff
prefix. V1 declares one: `gallery`.

That declaration is not a guess. `lib/l10n/app_en.arb` classifies the group in
its own metadata — `@galleryTitle.description` reads *"Title of the WP-9
acceptance artefact. Not a business screen."* Eight of the catalogue's 42
message keys carry the prefix, leaving 34 staff-facing. **Adopting it required
no change to any ARB file.**

An unclassified new key is treated as **staff-facing**. Forgetting to classify
errs toward enforcement, never toward a hole.

This is the current WP-9 convention, not a permanent multi-audience
architecture. Renaming a key silently changes its audience, which is the
convention's known weakness.

### 7. Matching is deterministic, and the negatives hold by construction

Values are lower-cased and split on every character that is not a Unicode
letter or digit; comparison is **token equality, never containment**. A phrase
matches as a consecutive token sequence.

That single choice is what makes `debits`, `debited` and `redebitable` safe
from `debit`, and would make `postcode` safe from a future `post` — not a rule
that could later be relaxed, but a consequence of how comparison works.

**Not used:** stemming · fuzzy matching · semantic similarity · embeddings ·
implicit inflection · uncontrolled substring matching. An inflection that
should be restricted needs its own business decision and its own row.

ICU braces become separators, so `=0{Not synced yet}` reads as words rather
than a mangled `0Not`. Argument names declared in `@key.placeholders`, ICU
keywords and bare numbers are then discarded — they are grammar, not words a
person reads. **Metadata is read for placeholder names only and is never
searched for policy violations.** A known, bounded limitation follows: a
restricted term identical to a declared placeholder name would be masked. No
current placeholder does this.

### 8. The self-test is the evidence, not the production scan

The clean catalogue contains no restricted term, so the production scan passes
— and a passing scan proves nothing by itself. `--selftest` builds synthetic
fixtures in memory and asserts **both halves**:

* **sensitivity** — the restricted term is detected, in every case, punctuation
  and mixed case included;
* **specificity** — inflections, substrings, non-staff keys, ARB keys, ARB
  metadata and ICU grammar do **not** produce a violation.

A scanner that matched nothing fails the first half; one that matched
everything fails the second. **A self-test that could pass by rejecting
everything is impossible by construction.**

Self-test fixtures are synthetic and are never registry entries, so exercising
phrase matching and the allowed-phrase collision rule requires no business
approval.

### 9. Enforced in CI, immediately after the hard-coded scan

`.github/workflows/ci.yml`, `database` job: self-test first, then the real
scan — the shape `scan_hardcoded.py` already established, and for the same
reason. Python 3 only, so ADR-0002's *"no build dependency beyond Python 3 and
psql"* still holds. A content defect is still caught when the Flutter job is
red for unrelated reasons.

**CI verifies conformity. CI is not business approval.**

### 10. The Controlled Business Evolution Gate

Adding, amending, deferring or withdrawing a term is an **ordinary business
policy change**:

    business need → business decision record → approved policy update
    → technical impact assessment → implementation → tests → CI

No ADR. No architecture review. A registry row and a BDR.

The architecture is reopened only when (a) an approved business requirement
cannot be represented by the policy model, or (b) a locked invariant must
change. Restricting a term from one staff group but not another would be such a
case; `audience_policy` carries no group dimension today. Nothing requires that
yet, and it has not been pre-built.

### 11. No exception mechanism

V1 has **no bypass**: no inline allowlist, no developer comment, no exception
file, no environment variable, no CI skip switch, no suppression rule.

A staff-facing need for a restricted term is a business decision — reclassify
the term or reclassify the key's audience — not a technical override. A future
exception mechanism would require separate governance approval; it is not an
implicit feature of this one.

## Consequences

* One approved term, one registry row, five files. Nothing about the catalogue,
  the glossary, the database or the existing scanners changed.
* `docs/staff-glossary.md` remains authoritative for approved staff vocabulary
  and is read, never written. Its synonym and tone rules are a separate policy
  from audience classification and are unaffected.
* `scan_hardcoded.py` is untouched and keeps its own job: it catches strings
  that never reached a catalogue. This one catches words that reached a
  catalogue and should not have. **Neither closes the other's gap** — a string
  extracted to a `const`, held in a list, or passed positionally to a custom
  widget still evades the first, and therefore never reaches the second.
* Hindi is outside V1 enforcement. `app_hi.arb` currently holds untranslated
  English stubs, so scanning it would pass by accident and decay silently once
  translation begins. **When genuine Hindi translation starts, Hindi vocabulary
  enforcement must be established before translated staff-facing content
  becomes enforceable.**
* The classification covers commercial and business-administration vocabulary;
  the V1 policy covers one accounting term. **The registry must not be read as
  covering the declared scope.** Production, inventory, tenancy and identity
  vocabulary have not been examined.

## Explicitly out of scope

Accounting transaction logic · journal processing · revenue recognition ·
customer advance accounting · Karigar settlement · workflow engine · Access
Governance / Gatekeeper · roles and permissions · RLS · Hindi enforcement ·
dark theme · terminology-management platform · proposal-management workflow ·
any database schema.

A18 does not implement accounting treatment. Accounting represents the
real-world transaction as it actually occurs; system convenience must not
distort it, and a vocabulary gate is not the place that decision gets made.
