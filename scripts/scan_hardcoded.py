#!/usr/bin/env python3
"""
Dhaaga hard-coded business rule scan.

AP-1: "any business rule a shop owner could reasonably want to change is data,
not code." BR-21 says the same thing from the other side: a literal threshold,
rate or window in application code is a defect, because the owner cannot reach
it and the CA sign-off cannot cover it.

This scan looks for rule-shaped literals: a numeric or quoted constant assigned
to, or compared against, an identifier whose name reads like a business rule -
rate, percent, threshold, tolerance, buffer, reserve, dormancy, capacity, fee,
discount, days, hours and so on.

It is a heuristic, so it is built to be trusted rather than believed:

  * --selftest plants a known violation and fails if the scan misses it, so a
    clean run means the scan works rather than that it looked nowhere;
  * the run reports how many files it read. Zero files scanned is a failure,
    not a pass;
  * an exception is declared in the code itself with a trailing or preceding
    "dhaaga:allow-literal <reason>" comment, so every exception is visible in
    the diff that introduces it and carries its justification.

Places where literals legitimately live are excluded by path: the configuration
registry and its shipped defaults (db/migrations/0004_configuration.sql), the
seed, and the test suite, which must be able to state expected values.

Usage:
    scan_hardcoded.py            scan and report
    scan_hardcoded.py --selftest prove the scan detects a planted violation
    scan_hardcoded.py --list     list the files that would be scanned
"""

from __future__ import annotations

import argparse
import re
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

# Application code, wherever it lives. Dart directories are listed ahead of
# their existence: WP-8 onward writes into them and the scan must already be
# watching when it does.
SCAN_ROOTS = ["lib", "app", "packages", "db/migrations", "db/rollback", "scripts", "supabase/functions"]
SCAN_SUFFIXES = {".dart", ".sql", ".py", ".ts", ".js"}

# Literals belong here by definition.
EXCLUDE_PATHS = {
    "db/migrations/0004_configuration.sql",   # the registry and its defaults
    "db/rollback/0004_configuration.down.sql",
    "scripts/scan_hardcoded.py",              # this file names the vocabulary
}
EXCLUDE_DIRS = {"db/seed", "db/tests", "db/verify", ".git", "node_modules", "build", ".dart_tool"}

RULE_WORDS = (
    "rate|percent|pct|threshold|tolerance|buffer|reserve|dormanc|quota|capacity"
    "|discount|fee|markup|margin|gst|vat|cess|surcharge|commission|penalty"
    "|retention|expiry|grace|slab|cutoff|min_order|max_order|lease_size"
    "|warn_after|target_seconds|_days|_hours|_minutes"
)

# name <op> literal, where the name reads like a business rule.
VIOLATION = re.compile(
    r"(?ix)"
    # The rule word may begin the identifier ("dormancyDays") or sit inside it
    # ("gstRate"), so the leading run must be allowed to match nothing.
    r"\b(?P<name>[\w.]*(?:" + RULE_WORDS + r")[\w.]*)\s*"
    r"(?P<op>:=|==|=|>=|<=|>|<)\s*"
    r"(?P<value>-?\d+(?:\.\d+)?\b|'[^']{1,40}'|\"[^\"]{1,40}\")"
)

# SQL keywords that the name pattern can otherwise swallow.
KEYWORD_NAMES = {"limit", "offset", "fetch", "rate", "percent"}

ALLOW = re.compile(r"dhaaga:allow-literal(?:\s+(?P<reason>.+))?")

# A literal that carries no business meaning on its own.
STRUCTURAL_VALUES = {"0", "1", "-1", "''", '""'}

GREEN = "\033[32m"
RED = "\033[31m"
DIM = "\033[2m"
RESET = "\033[0m"


class Finding:
    def __init__(self, path: Path, lineno: int, name: str, value: str, line: str):
        self.path, self.lineno, self.name, self.value, self.line = path, lineno, name, value, line

    def render(self, root: Path) -> str:
        rel = self.path.relative_to(root)
        return (f"  {rel}:{self.lineno}\n"
                f"      {self.name} = {self.value}\n"
                f"      {DIM}{self.line.strip()[:110]}{RESET}")


def is_excluded(path: Path, root: Path) -> bool:
    rel = path.relative_to(root).as_posix()
    if rel in EXCLUDE_PATHS:
        return True
    return any(rel == d or rel.startswith(d + "/") for d in EXCLUDE_DIRS)


def discover(root: Path) -> list[Path]:
    files: list[Path] = []
    for name in SCAN_ROOTS:
        base = root / name
        if not base.is_dir():
            continue
        for path in sorted(base.rglob("*")):
            if path.is_file() and path.suffix in SCAN_SUFFIXES and not is_excluded(path, root):
                files.append(path)
    return files


def scan_file(path: Path) -> list[Finding]:
    findings: list[Finding] = []
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return findings

    for index, line in enumerate(lines, start=1):
        if ALLOW.search(line):
            continue
        # An allowance may sit on the line above, which is how a multi-line
        # declaration declares itself.
        if index >= 2 and ALLOW.search(lines[index - 2]):
            continue
        for match in VIOLATION.finditer(line):
            name = match.group("name")
            if name.lower() in KEYWORD_NAMES:
                continue
            value = match.group("value")
            if value in STRUCTURAL_VALUES:
                continue
            findings.append(Finding(path, index, name, value, line))
    return findings


def run(root: Path, quiet: bool = False) -> tuple[int, list[Finding]]:
    files = discover(root)
    findings: list[Finding] = []
    for path in files:
        findings.extend(scan_file(path))
    if not quiet:
        print()
        print(f"hard-coded business rule scan  {DIM}({len(files)} files){RESET}")
        print()
        if findings:
            for finding in findings:
                print(finding.render(root))
            print()
            print(f"{RED}FAILED{RESET}  {len(findings)} rule-shaped literal(s) in application code")
            print("        Move the value into config_setting, or declare the exception with a")
            print("        'dhaaga:allow-literal <reason>' comment on or above the line.")
            print()
        elif len(files) == 0:
            print(f"{RED}FAILED{RESET}  no files scanned - a clean result would be vacuous")
            print()
        else:
            print(f"{GREEN}PASSED{RESET}  no rule-shaped literals in {len(files)} files")
            print()
    return len(files), findings


def selftest() -> int:
    """A clean scan is only evidence if the scan can fail."""
    print()
    print("scan self-test")
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

    with tempfile.TemporaryDirectory() as tmp:
        fake = Path(tmp)
        (fake / "lib").mkdir()
        planted = fake / "lib" / "pricing.dart"
        planted.write_text(
            "class Pricing {\n"
            "  static const double gstRate = 18.0;\n"
            "  static const int dormancyDays = 270;\n"
            "  int lineCount = 1;\n"
            "  // dhaaga:allow-literal the schema itself fixes two decimal places\n"
            "  static const int moneyScale = 2;\n"
            "  static const double reworkReservePercent = 12.0; // dhaaga:allow-literal deliberate\n"
            "}\n",
            encoding="utf-8",
        )
        count, findings = run(fake, quiet=True)
        names = sorted(f.name for f in findings)

        check("the scan reads planted files", count == 1, f"scanned {count}")
        check("a hard-coded tax rate is found", "gstRate" in names, str(names))
        check("a hard-coded dormancy window is found", "dormancyDays" in names, str(names))
        check("a structural literal is not reported", "lineCount" not in names, str(names))
        check("an allowance on the line above is honoured", "moneyScale" not in names, str(names))
        check("an allowance on the line itself is honoured",
              "reworkReservePercent" not in names, str(names))
        check("nothing else is reported", len(findings) == 2, str(names))

        empty = Path(tmp) / "empty"
        empty.mkdir()
        zero_count, _ = run(empty, quiet=True)
        check("an empty tree scans zero files, which the run treats as a failure", zero_count == 0)

    print()
    if failed:
        print(f"{RED}FAILED{RESET}  {passed} passed, {failed} failed")
        print()
        return 1
    print(f"{GREEN}PASSED{RESET}  {passed} checks")
    print()
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Dhaaga hard-coded business rule scan")
    parser.add_argument("--selftest", action="store_true", help="prove the scan detects a planted violation")
    parser.add_argument("--list", action="store_true", help="list the files that would be scanned")
    args = parser.parse_args()

    if args.selftest:
        return selftest()

    if args.list:
        for path in discover(REPO_ROOT):
            print(path.relative_to(REPO_ROOT))
        return 0

    count, findings = run(REPO_ROOT)
    return 1 if (findings or count == 0) else 0


if __name__ == "__main__":
    raise SystemExit(main())
