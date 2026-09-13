#!/usr/bin/env python3
"""
Dhaaga A18 — staff-facing vocabulary policy scan.

WHAT THIS ENFORCES, AND WHAT IT DOES NOT

This script enforces an APPROVED BUSINESS POLICY. It does not create one.

    Business Decision  ->  Approved Policy  ->  Technical Enforcement  ->  Verification
    (A18-BDR-001)          (the registry)       (this script)             (CI)

Every term this script enforces exists because a Business Owner decided it and
recorded that decision in a Business Decision Record. The registry is the
machine-checkable representation of those decisions and nothing else. A commit,
a pull request, a green CI run and this script's own success are NOT business
approval, and the validator below refuses to run a policy whose `bdr_reference`
does not resolve to real business evidence.

    A18 is Dhaaga's Commercial & Business Administration Vocabulary
    Classification. Accounting is ONE DOMAIN within it. An accounting term is
    NOT automatically forbidden: `debit` is restricted from STAFF-FACING
    English message values and remains entirely valid in internal,
    administrative, technical, accounting and database contexts.

THE REGISTRY IS DELIBERATELY NON-EXHAUSTIVE.

V1 holds exactly one approved term. Vocabulary grows by business decision
through the Controlled Business Evolution Gate - a new BDR and a new registry
row - never by a developer's judgement and never by editing this file.

WHAT IS SCANNED

    lib/l10n/app_en.arb, MESSAGE VALUES ONLY, staff-facing keys only.

Never scanned: ARB keys - ARB metadata and @descriptions - generated
localisation Dart - app_hi.arb (Hindi is out of V1 scope) - database content -
migrations - seed data - tenant-owned vocabulary - developer-only text.

The one exception, stated so it cannot be mistaken for scanning metadata: a
key's `@key.placeholders` names are read to EXCLUDE ICU argument names from
tokenisation. Metadata is never searched for policy violations.

MATCHING IS DETERMINISTIC

Case-insensitive, whole-token only. No stemming, no fuzzy matching, no
semantic similarity, no implicit inflection, no uncontrolled substring
matching. `debits`, `debited` and `redistribute` do not match `debit`; a term
containing whitespace is matched as a consecutive token sequence.

THERE IS NO BYPASS

No inline allowlist, no developer comment, no exception file, no environment
variable, no CI skip. A staff-facing need for a restricted term is a business
decision, not a technical override.

Usage:
    scan_vocabulary.py             validate the policy, then scan
    scan_vocabulary.py --selftest  prove the scanner detects and discriminates
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

POLICY_PATH = Path("policy") / "a18_vocabulary_policy.json"
CATALOGUE_PATH = Path("lib") / "l10n" / "app_en.arb"
BDR_DIR = Path("docs") / "decisions"

SCHEMA_VERSION = 1

# The complete set of fields a policy row may carry. Anything else is rejected.
# `enforced` is deliberately absent: enforcement is DERIVED from the approved
# policy state and may never be stored independently, because a stored flag can
# contradict the decision it claims to represent.
TERM_FIELDS = {
    "term",
    "decision_status",
    "audience_policy",
    "reason",
    "bdr_reference",
}

DECISION_STATUS_VALUES = {"approved", "deferred"}
AUDIENCE_POLICY_VALUES = {"staff-restricted", "staff-allowed"}

# ICU structural vocabulary. These are grammar, not words a person reads.
ICU_KEYWORDS = {
    "plural",
    "select",
    "selectordinal",
    "offset",
    "zero",
    "one",
    "two",
    "few",
    "many",
    "other",
}

BDR_REFERENCE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")

GREEN = "\033[32m"
RED = "\033[31m"
DIM = "\033[2m"
RESET = "\033[0m"


class PolicyError(Exception):
    """The policy is malformed or violates a registry invariant."""


class CatalogueError(Exception):
    """The catalogue is missing, unparseable, or carries no messages."""


# ---------------------------------------------------------------------------
# Policy loading and registry invariants
# ---------------------------------------------------------------------------

def load_policy(root: Path) -> dict:
    path = root / POLICY_PATH
    if not path.is_file():
        raise PolicyError(f"policy file not found: {POLICY_PATH.as_posix()}")
    try:
        raw = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise PolicyError(f"policy file unreadable: {exc}") from exc
    if not raw.strip():
        raise PolicyError(f"policy file is empty: {POLICY_PATH.as_posix()}")
    try:
        policy = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise PolicyError(f"policy file is not valid JSON: {exc}") from exc
    if not isinstance(policy, dict):
        raise PolicyError("policy file must contain a JSON object")
    return policy


def resolve_bdr(root: Path, reference: str) -> None:
    """Invariant 4: a bdr_reference must resolve to real business evidence.

    This is the invariant that a previous implementation attempt was correctly
    blocked on: the referenced record existed at its path and was zero bytes.
    A reference that resolves to nothing is not evidence, so existence alone is
    not accepted - the record must be non-empty and must identify itself.
    """
    path = root / BDR_DIR / f"{reference}.md"
    if not path.is_file():
        raise PolicyError(
            f"bdr_reference '{reference}' does not resolve: "
            f"{(BDR_DIR / (reference + '.md')).as_posix()} not found"
        )
    try:
        content = path.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        raise PolicyError(f"bdr_reference '{reference}' is unreadable: {exc}") from exc
    if not content.strip():
        raise PolicyError(
            f"bdr_reference '{reference}' resolves to an EMPTY record: "
            f"{(BDR_DIR / (reference + '.md')).as_posix()} records no business decision"
        )
    if f"Record ID: {reference}" not in content:
        raise PolicyError(
            f"bdr_reference '{reference}' resolves to a record that does not "
            f"identify itself as '{reference}' (expected a line 'Record ID: {reference}')"
        )


def validate_policy(policy: dict, root: Path) -> list[dict]:
    """Enforce every registry invariant. Raises PolicyError on the first failure."""
    if policy.get("schema_version") != SCHEMA_VERSION:
        raise PolicyError(
            f"schema_version must be {SCHEMA_VERSION}, got {policy.get('schema_version')!r}"
        )

    # Invariant 8: the registry is non-exhaustive, and says so about itself.
    if policy.get("non_exhaustive") is not True:
        raise PolicyError("non_exhaustive must be true: the registry is not a complete vocabulary")

    scope = policy.get("scope")
    if not isinstance(scope, dict):
        raise PolicyError("scope must be an object")
    if not isinstance(scope.get("catalogue"), str) or not scope["catalogue"].strip():
        raise PolicyError("scope.catalogue must be a non-empty string")
    prefixes = scope.get("non_staff_key_prefixes")
    if not isinstance(prefixes, list):
        raise PolicyError("scope.non_staff_key_prefixes must be a list")
    for prefix in prefixes:
        if not isinstance(prefix, str) or not prefix or prefix != prefix.strip():
            raise PolicyError(f"non-staff key prefix must be a trimmed non-empty string: {prefix!r}")
    if not isinstance(scope.get("non_staff_prefix_evidence"), str) or not scope[
        "non_staff_prefix_evidence"
    ].strip():
        raise PolicyError(
            "scope.non_staff_prefix_evidence must cite the repository evidence for the "
            "non-staff prefixes: staff-facing scope may not be guessed"
        )

    terms = policy.get("terms")
    if not isinstance(terms, list):
        raise PolicyError("terms must be a list")

    seen: set[str] = set()
    for entry in terms:
        if not isinstance(entry, dict):
            raise PolicyError(f"each policy row must be an object, got {type(entry).__name__}")

        # Invariant 7: no independently maintained enforcement state. An unknown
        # field is refused rather than ignored, so a stored `enforced` flag can
        # never be introduced quietly.
        unknown = set(entry) - TERM_FIELDS
        if unknown:
            raise PolicyError(
                f"policy row carries unknown field(s) {sorted(unknown)}; "
                f"allowed fields are {sorted(TERM_FIELDS)}. Enforcement is derived, never stored."
            )
        missing = TERM_FIELDS - set(entry)
        if missing:
            raise PolicyError(f"policy row is missing field(s) {sorted(missing)}")

        term = entry["term"]
        if not isinstance(term, str) or not term.strip():
            raise PolicyError("term must be a non-empty string")
        if term != term.strip() or term != term.lower():
            raise PolicyError(f"term must be lowercase and trimmed: {term!r}")

        key = term.lower()
        if key in seen:
            raise PolicyError(f"duplicate term (case-insensitive): {term!r}")
        seen.add(key)

        status = entry["decision_status"]
        # Invariant 5: UNRESOLVED candidates never appear. There is no
        # 'unresolved' value - absence from this file IS unresolved.
        if status not in DECISION_STATUS_VALUES:
            raise PolicyError(
                f"{term!r}: decision_status must be one of {sorted(DECISION_STATUS_VALUES)}, "
                f"got {status!r}. An unresolved term is absent from the registry, not listed in it."
            )

        audience = entry["audience_policy"]
        if audience not in AUDIENCE_POLICY_VALUES:
            raise PolicyError(
                f"{term!r}: audience_policy must be one of {sorted(AUDIENCE_POLICY_VALUES)}, "
                f"got {audience!r}"
            )

        if status == "deferred" and audience != "staff-restricted":
            raise PolicyError(
                f"{term!r}: a deferred decision only has meaning for a staff-restricted term"
            )

        reason = entry["reason"]
        if not isinstance(reason, str) or not reason.strip():
            raise PolicyError(f"{term!r}: reason must be non-empty and derived from its BDR")

        reference = entry["bdr_reference"]
        if not isinstance(reference, str) or not BDR_REFERENCE_RE.match(reference):
            raise PolicyError(f"{term!r}: bdr_reference is not a usable reference: {reference!r}")
        resolve_bdr(root, reference)

    _assert_no_enforced_term_inside_allowed_phrase(terms)
    return terms


def is_enforced(entry: dict) -> bool:
    """Enforcement is derived, never stored."""
    return entry["decision_status"] == "approved" and entry["audience_policy"] == "staff-restricted"


def term_tokens(term: str) -> list[str]:
    return tokenise(term.lower())


def _assert_no_enforced_term_inside_allowed_phrase(terms: list[dict]) -> None:
    """V10 - a policy may not both forbid and permit the same words.

    Inert against a registry that holds no staff-allowed phrase, and implemented
    anyway: adding a validation rule to an already-enforcing gate is the change
    most likely to be skipped later.
    """
    allowed_phrases = [
        entry
        for entry in terms
        if entry["audience_policy"] == "staff-allowed" and len(term_tokens(entry["term"])) > 1
    ]
    if not allowed_phrases:
        return
    for entry in terms:
        if not is_enforced(entry):
            continue
        needle = term_tokens(entry["term"])
        for phrase in allowed_phrases:
            haystack = term_tokens(phrase["term"])
            if _contains_sequence(haystack, needle):
                raise PolicyError(
                    f"contradictory policy: {entry['term']!r} is enforced but occurs inside the "
                    f"staff-allowed phrase {phrase['term']!r}. Resolve the policy - allow the "
                    f"term, withdraw the phrase, or defer the term - the scanner will not "
                    f"decide this at scan time."
                )


def _contains_sequence(haystack: list[str], needle: list[str]) -> bool:
    if not needle or len(needle) > len(haystack):
        return False
    span = len(needle)
    return any(haystack[i : i + span] == needle for i in range(len(haystack) - span + 1))


# ---------------------------------------------------------------------------
# Catalogue loading and staff-facing scope
# ---------------------------------------------------------------------------

def load_catalogue(root: Path, relative: str) -> dict:
    path = root / relative
    if not path.is_file():
        raise CatalogueError(f"catalogue not found: {relative}")
    try:
        raw = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise CatalogueError(f"catalogue unreadable: {exc}") from exc
    try:
        arb = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise CatalogueError(f"catalogue is not valid JSON: {exc}") from exc
    if not isinstance(arb, dict):
        raise CatalogueError("catalogue must contain a JSON object")
    return arb


def message_entries(arb: dict) -> list[tuple[str, str]]:
    """Message keys and their values. Metadata keys and @@locale are not messages."""
    return [
        (key, value)
        for key, value in arb.items()
        if not key.startswith("@") and isinstance(value, str)
    ]


def is_staff_facing(key: str, prefixes: list[str]) -> bool:
    """A key is staff-facing unless it carries a declared non-staff prefix.

    Fail-safe by design: a new key that nobody classified is protected, not
    exempt. Forgetting to classify errs toward enforcement.
    """
    return not any(key.startswith(prefix) for prefix in prefixes)


def placeholder_names(arb: dict, key: str) -> set[str]:
    meta = arb.get(f"@{key}")
    if not isinstance(meta, dict):
        return set()
    placeholders = meta.get("placeholders")
    if not isinstance(placeholders, dict):
        return set()
    return {name.lower() for name in placeholders if isinstance(name, str)}


# ---------------------------------------------------------------------------
# Deterministic matching
# ---------------------------------------------------------------------------

def tokenise(text: str) -> list[str]:
    """Split on every character that is not a Unicode letter or digit.

    Token equality - never containment - is what makes `postcode` safe from a
    term `post` and `debits` safe from `debit`. The negatives hold by
    construction rather than by a rule that could later be relaxed.
    """
    tokens: list[str] = []
    current: list[str] = []
    for ch in text:
        if ch.isalnum():
            current.append(ch)
        elif current:
            tokens.append("".join(current))
            current = []
    if current:
        tokens.append("".join(current))
    return tokens


def normalise(value: str, placeholders: set[str]) -> list[str]:
    """Message value -> comparable tokens.

    ICU braces become separators so `=0{Not synced yet}` yields `not synced yet`
    rather than a mangled `0Not`. Argument names, ICU keywords and bare numbers
    are then dropped: they are grammar, not words a person reads.
    """
    flattened = value.replace("{", " ").replace("}", " ")
    tokens = [token.lower() for token in tokenise(flattened)]
    return [
        token
        for token in tokens
        if token not in ICU_KEYWORDS and token not in placeholders and not token.isdigit()
    ]


def find_violations(tokens: list[str], enforced: list[dict]) -> list[dict]:
    hits = []
    for entry in enforced:
        needle = term_tokens(entry["term"])
        matched = (
            needle[0] in tokens if len(needle) == 1 else _contains_sequence(tokens, needle)
        )
        if matched:
            hits.append(entry)
    return hits


# ---------------------------------------------------------------------------
# Scan
# ---------------------------------------------------------------------------

class Finding:
    def __init__(self, key: str, entry: dict, value: str):
        self.key = key
        self.entry = entry
        self.value = value

    def render(self) -> str:
        return (
            f"  {self.key}\n"
            f"      restricted term: {self.entry['term']}\n"
            f"      approved by:     {self.entry['bdr_reference']}\n"
            f"      {DIM}{self.value.strip()[:110]}{RESET}"
        )


def scan(root: Path, quiet: bool = False) -> tuple[int, int, list[Finding]]:
    policy = load_policy(root)
    terms = validate_policy(policy, root)
    enforced = [entry for entry in terms if is_enforced(entry)]

    scope = policy["scope"]
    arb = load_catalogue(root, scope["catalogue"])
    messages = message_entries(arb)
    if not messages:
        raise CatalogueError(
            f"catalogue {scope['catalogue']} parsed but carries no message entries - "
            f"a clean result would be vacuous"
        )

    prefixes = scope["non_staff_key_prefixes"]
    findings: list[Finding] = []
    scanned = 0
    for key, value in messages:
        if not is_staff_facing(key, prefixes):
            continue
        scanned += 1
        tokens = normalise(value, placeholder_names(arb, key))
        for entry in find_violations(tokens, enforced):
            findings.append(Finding(key, entry, value))

    if quiet:
        return scanned, len(enforced), findings

    print()
    print(
        f"staff vocabulary scan  {DIM}({scanned} staff-facing message(s), "
        f"{len(enforced)} enforced term(s)){RESET}"
    )
    print()

    if findings:
        print(f"{RED}restricted vocabulary in staff-facing text{RESET}  {DIM}(A18){RESET}")
        for finding in findings:
            print(finding.render())
        print()
        print("        Use approved staff vocabulary, or raise a business decision to")
        print("        reclassify the term. There is no technical bypass by design.")
        print()
        print(f"{RED}FAILED{RESET}  {len(findings)} restricted-vocabulary use(s)")
        print()
    elif len(enforced) == 0:
        print(f"{GREEN}PASSED{RESET}  no enforced terms; no staff vocabulary policy is in force")
        print()
    else:
        print(
            f"{GREEN}PASSED{RESET}  no restricted vocabulary in {scanned} staff-facing message(s)"
        )
        print()

    return scanned, len(enforced), findings


# ---------------------------------------------------------------------------
# Self-test
# ---------------------------------------------------------------------------

_BDR_FIXTURE = """# TEST-BDR-001 - Business Decision Record

## Record Identity

- Record ID: TEST-BDR-001
"""


def _fixture_root(tmp: Path, arb: dict, terms: list[dict], *, bdr: bool = True) -> Path:
    root = tmp
    (root / "policy").mkdir(parents=True, exist_ok=True)
    (root / "lib" / "l10n").mkdir(parents=True, exist_ok=True)
    (root / "docs" / "decisions").mkdir(parents=True, exist_ok=True)
    if bdr:
        (root / "docs" / "decisions" / "TEST-BDR-001.md").write_text(
            _BDR_FIXTURE, encoding="utf-8"
        )
    (root / "lib" / "l10n" / "app_en.arb").write_text(json.dumps(arb), encoding="utf-8")
    (root / POLICY_PATH).write_text(
        json.dumps(
            {
                "schema_version": SCHEMA_VERSION,
                "policy_id": "SELFTEST",
                "non_exhaustive": True,
                "scope": {
                    "catalogue": CATALOGUE_PATH.as_posix(),
                    "scans": "message values only",
                    "non_staff_key_prefixes": ["gallery"],
                    "non_staff_prefix_evidence": "self-test fixture",
                },
                "terms": terms,
            }
        ),
        encoding="utf-8",
    )
    return root


def _row(term: str, status: str = "approved", audience: str = "staff-restricted") -> dict:
    return {
        "term": term,
        "decision_status": status,
        "audience_policy": audience,
        "reason": "self-test fixture",
        "bdr_reference": "TEST-BDR-001",
    }


def selftest() -> int:
    """A clean scan is only evidence if the scan can fail - and can also refrain.

    Sensitivity proves the restricted term is detected. Specificity proves the
    scanner is not simply rejecting everything. Both halves must hold, so a
    scanner that matched nothing and a scanner that matched everything each fail
    here.
    """
    print()
    print("staff vocabulary scan self-test")
    print()
    passed = failed = 0

    def check(name: str, condition: bool, detail: str = "") -> None:
        nonlocal passed, failed
        if condition:
            passed += 1
            print(f"{GREEN}ok{RESET}    {name}")
        else:
            failed += 1
            print(f"{RED}FAIL{RESET}  {name}\n      {detail}")

    def run(arb: dict, terms: list[dict] | None = None):
        with tempfile.TemporaryDirectory() as tmp:
            root = _fixture_root(Path(tmp), arb, terms if terms is not None else [_row("debit")])
            return scan(root, quiet=True)

    def keys_hit(arb: dict, terms: list[dict] | None = None) -> list[str]:
        _, _, findings = run(arb, terms)
        return [f.key for f in findings]

    def meta(description: str) -> dict:
        return {"description": description}

    # -- sensitivity: the approved restricted term is detected ---------------
    check(
        "a staff-facing value containing 'debit' is detected",
        keys_hit({"orderNote": "Record the debit against this order"}) == ["orderNote"],
    )
    check(
        "detection is case-insensitive - DEBIT",
        keys_hit({"orderNote": "Record the DEBIT here"}) == ["orderNote"],
    )
    check(
        "detection is case-insensitive - Debit",
        keys_hit({"orderNote": "Debit recorded"}) == ["orderNote"],
    )
    check(
        "trailing punctuation does not hide the term",
        keys_hit({"orderNote": "Debit."}) == ["orderNote"],
    )
    check(
        "a hyphen is a token boundary",
        keys_hit({"orderNote": "debit-side total"}) == ["orderNote"],
    )
    check(
        "the term is found inside a longer sentence",
        keys_hit({"orderNote": "Please confirm the debit before closing"}) == ["orderNote"],
    )

    # -- specificity: the scanner discriminates ------------------------------
    check(
        "'debits' does not match 'debit' (no implicit inflection)",
        keys_hit({"orderNote": "Two debits were recorded"}) == [],
    )
    check(
        "'debited' does not match 'debit' (no stemming)",
        keys_hit({"orderNote": "The account was debited"}) == [],
    )
    check(
        "an embedded substring does not match",
        keys_hit({"orderNote": "redebitable placeholder text"}) == [],
    )
    check(
        "safe staff-facing text passes",
        keys_hit({"stateEmpty": "Nothing here yet", "actionRetry": "Try again"}) == [],
    )

    # -- scope: what is and is not enforced ----------------------------------
    check(
        "a non-staff (gallery) key is not enforced",
        keys_hit({"galleryDebitSample": "debit"}) == [],
    )
    check(
        "an ARB KEY named for the term is not scanned",
        keys_hit({"debit": "Nothing here yet"}) == [],
    )
    check(
        "ARB metadata and @descriptions are not scanned",
        keys_hit({"stateEmpty": "Nothing here yet", "@stateEmpty": meta("mentions debit")}) == [],
    )
    check(
        "an unclassified new key is treated as staff-facing (fail-safe)",
        keys_hit({"someBrandNewKey": "debit"}) == ["someBrandNewKey"],
    )

    # -- ICU handling --------------------------------------------------------
    icu_clean = {
        "offlineUnsynced": "{hours, plural, =0{Not synced yet} other{Unsynced for {hours} hours}}",
        "@offlineUnsynced": {"placeholders": {"hours": {"type": "int"}}},
    }
    check(
        "ICU keywords, argument names and digits raise no false positive",
        keys_hit(icu_clean, [_row("plural"), _row("other"), _row("hours")]) == [],
    )
    check(
        "a restricted term inside an ICU sub-message is still detected",
        keys_hit(
            {
                "icuDebit": "{n, plural, other{{n} debit lines}}",
                "@icuDebit": {"placeholders": {"n": {"type": "int"}}},
            }
        )
        == ["icuDebit"],
    )

    # -- phrase matching -----------------------------------------------------
    phrase = [_row("trial balance")]
    check(
        "a configured phrase matches as a consecutive token sequence",
        keys_hit({"reportTitle": "Open the trial balance"}, phrase) == ["reportTitle"],
    )
    check(
        "the first word of a phrase alone does not match",
        keys_hit({"fittingLabel": "Trial"}, phrase) == [],
    )
    check(
        "phrase tokens out of order do not match",
        keys_hit({"reportTitle": "balance trial"}, phrase) == [],
    )

    # -- derived enforcement -------------------------------------------------
    check(
        "a deferred term is not enforced",
        keys_hit({"orderNote": "debit"}, [_row("debit", status="deferred")]) == [],
    )
    check(
        "a staff-allowed term is not enforced",
        keys_hit({"orderNote": "debit"}, [_row("debit", audience="staff-allowed")]) == [],
    )

    # -- registry invariants fail deterministically --------------------------
    def rejects(name: str, terms: list[dict] | None = None, mutate=None, bdr: bool = True) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = _fixture_root(
                Path(tmp), {"orderNote": "safe"}, terms if terms is not None else [_row("debit")], bdr=bdr
            )
            if mutate is not None:
                mutate(root)
            try:
                scan(root, quiet=True)
            except PolicyError:
                check(name, True)
                return
            except CatalogueError as exc:
                check(name, False, f"raised CatalogueError instead: {exc}")
                return
            check(name, False, "policy was accepted but should have been rejected")

    rejects("a stored 'enforced' field is refused", [{**_row("debit"), "enforced": True}])
    rejects("an unknown decision_status is refused", [_row("debit", status="unresolved")])
    rejects("an unknown audience_policy is refused", [_row("debit", audience="everyone")])
    rejects("deferred + staff-allowed is refused", [_row("debit", status="deferred", audience="staff-allowed")])
    rejects("an uppercase term is refused", [_row("Debit")])
    rejects("a duplicate term is refused", [_row("debit"), _row("debit")])
    rejects("an empty reason is refused", [{**_row("debit"), "reason": "   "}])
    rejects("a missing field is refused", [{k: v for k, v in _row("debit").items() if k != "reason"}])
    rejects("an unresolvable bdr_reference is refused", [{**_row("debit"), "bdr_reference": "NO-SUCH-BDR"}])
    rejects("an EMPTY bdr record is refused", bdr=True,
            mutate=lambda root: (root / "docs" / "decisions" / "TEST-BDR-001.md").write_text("", encoding="utf-8"))
    rejects("a bdr record that does not identify itself is refused",
            mutate=lambda root: (root / "docs" / "decisions" / "TEST-BDR-001.md").write_text("# unrelated\n", encoding="utf-8"))
    rejects("a missing bdr record is refused", bdr=False)
    rejects("malformed JSON is refused",
            mutate=lambda root: (root / POLICY_PATH).write_text("{ not json", encoding="utf-8"))
    rejects("an empty policy file is refused",
            mutate=lambda root: (root / POLICY_PATH).write_text("", encoding="utf-8"))
    rejects("a contradictory policy - enforced word inside an allowed phrase - is refused",
            [_row("credit"), _row("credit note", audience="staff-allowed")])

    # -- catalogue failure semantics -----------------------------------------
    def catalogue_rejects(name: str, mutate) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = _fixture_root(Path(tmp), {"orderNote": "safe"}, [_row("debit")])
            mutate(root)
            try:
                scan(root, quiet=True)
            except CatalogueError:
                check(name, True)
                return
            except PolicyError as exc:
                check(name, False, f"raised PolicyError instead: {exc}")
                return
            check(name, False, "catalogue was accepted but should have been rejected")

    catalogue_rejects("a catalogue with zero messages is a failure, not a clean pass",
                      lambda root: (root / CATALOGUE_PATH).write_text("{}", encoding="utf-8"))
    catalogue_rejects("an unparseable catalogue is a failure",
                      lambda root: (root / CATALOGUE_PATH).write_text("{ not json", encoding="utf-8"))
    catalogue_rejects("a missing catalogue is a failure",
                      lambda root: (root / CATALOGUE_PATH).unlink())

    # -- the self-test cannot pass vacuously ---------------------------------
    scanned, enforced_count, findings = run({"orderNote": "Record the debit"})
    check("the self-test actually scanned a staff-facing message", scanned == 1, f"scanned {scanned}")
    check("the self-test actually had an enforced term", enforced_count == 1)
    check("the expected violation was detected", len(findings) == 1)

    print()
    if failed:
        print(f"{RED}FAILED{RESET}  {passed} passed, {failed} failed")
        print()
        return 1
    print(f"{GREEN}PASSED{RESET}  {passed} checks - detection and discrimination both proven")
    print()
    return 0


# ---------------------------------------------------------------------------

def main() -> int:
    parser = argparse.ArgumentParser(description="Dhaaga A18 staff vocabulary policy scan")
    parser.add_argument(
        "--selftest", action="store_true", help="prove the scanner detects and discriminates"
    )
    args = parser.parse_args()

    if args.selftest:
        return selftest()

    try:
        _, _, findings = scan(REPO_ROOT)
    except PolicyError as exc:
        print()
        print(f"{RED}FAILED{RESET}  approved policy is invalid: {exc}")
        print()
        return 1
    except CatalogueError as exc:
        print()
        print(f"{RED}FAILED{RESET}  {exc}")
        print()
        return 1

    return 1 if findings else 0


if __name__ == "__main__":
    raise SystemExit(main())
