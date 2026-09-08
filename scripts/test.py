#!/usr/bin/env python3
"""
Dhaaga database test runner.

Every test file in db/tests/ runs inside a transaction that is always rolled
back, so tests never leave residue and can run against a migrated database
without a teardown step.

Assertions live in db/tests/_helpers.sql and are loaded into each transaction
before the test file. An assertion that fails raises; an assertion that passes
emits "ok - <name>" as a NOTICE, which is what this runner counts. That means a
test file that silently does nothing reports zero assertions and is flagged,
rather than passing by omission.

Usage:
    test.py                 run every test file
    test.py customers       run test files whose name contains "customers"
    test.py --list          list discovered test files

Environment:
    DHAAGA_DB_URL   postgres connection URL (required)
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

# Load .env ourselves rather than relying on the shell to have sourced it.
# PowerShell has no `source`, so the previous instruction was unusable on
# Windows; see scripts/env_loader.py. A variable already set in the environment
# always wins, which is what keeps `DHAAGA_DB_URL=<scratch> python3 ...` correct
# in the test harnesses.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from env_loader import EnvError, require_psql, require_url  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent
TESTS_DIR = REPO_ROOT / "db" / "tests"
HELPERS = TESTS_DIR / "_helpers.sql"

# psql prefixes notices from a file with "psql:<file>:<line>: ", so match anywhere
# on the line rather than anchoring at the start.
OK_RE = re.compile(r"NOTICE:\s+ok - (.*)$")
FORBIDDEN = re.compile(r"^\s*(commit|end)\s*;", re.IGNORECASE | re.MULTILINE)

GREEN = "\033[32m"
RED = "\033[31m"
DIM = "\033[2m"
RESET = "\033[0m"


def db_url() -> str:
    try:
        require_psql()
        return require_url("DHAAGA_DB_URL")
    except EnvError as exc:
        print(f"\nconfiguration error: {exc}\n", file=sys.stderr)
        raise SystemExit(2)


def discover(filter_text: str | None) -> list[Path]:
    if not TESTS_DIR.is_dir():
        print(f"missing tests directory: {TESTS_DIR}", file=sys.stderr)
        raise SystemExit(2)
    files = sorted(
        p for p in TESTS_DIR.glob("*.sql") if not p.name.startswith("_")
    )
    if filter_text:
        files = [p for p in files if filter_text in p.name]
    return files


def run_file(path: Path) -> tuple[list[str], str | None]:
    """Returns (passed_assertion_names, failure_message_or_None)."""
    body = path.read_text(encoding="utf-8")
    if FORBIDDEN.search(body):
        return [], "test file contains COMMIT/END, which would defeat rollback isolation"

    with tempfile.NamedTemporaryFile("w", suffix=".sql", delete=False) as handle:
        handle.write("\\set ON_ERROR_STOP on\n")
        handle.write("begin;\n")
        # as_posix(), not str(): psql ends a meta-command argument at the first
        # unquoted backslash, so a Windows path renders `\i C:\repo\db\...` and
        # psql opens a file called `C:` - "Permission denied" on Windows, at
        # line 3 of this driver. Forward slashes are accepted by psql on
        # Windows, and as_posix() is a no-op on Linux and in CI.
        handle.write(f"\\i {HELPERS.as_posix()}\n")
        handle.write(f"\\i {path.as_posix()}\n")
        handle.write("rollback;\n")
        driver = handle.name

    try:
        proc = subprocess.run(
            ["psql", "-v", "ON_ERROR_STOP=1", "--no-psqlrc", "-q", "-f", driver, db_url()],
            capture_output=True,
            text=True,
        )
    finally:
        os.unlink(driver)

    passed = [
        match.group(1)
        for line in proc.stderr.splitlines()
        if (match := OK_RE.search(line.strip()))
    ]

    if proc.returncode != 0:
        detail = [
            line.strip()
            for line in proc.stderr.splitlines()
            if any(tag in line for tag in ("ERROR:", "DETAIL:", "HINT:"))
        ]
        return passed, "\n      ".join(detail) or proc.stderr.strip()

    if not passed:
        return passed, "no assertions ran - a test file that asserts nothing is a failing test"

    return passed, None


def main() -> int:
    parser = argparse.ArgumentParser(description="Dhaaga database test runner")
    parser.add_argument("filter", nargs="?", help="substring filter on test filename")
    parser.add_argument("--list", action="store_true", help="list test files and exit")
    parser.add_argument("--verbose", "-v", action="store_true", help="print every assertion")
    args = parser.parse_args()

    files = discover(args.filter)
    if args.list:
        for path in files:
            print(path.name)
        return 0

    if not files:
        print("no test files found", file=sys.stderr)
        return 2

    if not HELPERS.exists():
        print(f"missing {HELPERS}", file=sys.stderr)
        return 2

    total_assertions = 0
    failed_files: list[str] = []

    print()
    for path in files:
        passed, failure = run_file(path)
        total_assertions += len(passed)
        if failure:
            failed_files.append(path.name)
            print(f"{RED}FAIL{RESET}  {path.name}  {DIM}({len(passed)} passed before failure){RESET}")
            print(f"      {failure}")
        else:
            print(f"{GREEN}ok{RESET}    {path.name}  {DIM}{len(passed)} assertions{RESET}")
        if args.verbose:
            for name in passed:
                print(f"        {DIM}· {name}{RESET}")

    print()
    if failed_files:
        print(f"{RED}FAILED{RESET}  {len(failed_files)} of {len(files)} files, "
              f"{total_assertions} assertions passed")
        return 1

    print(f"{GREEN}PASSED{RESET}  {len(files)} files, {total_assertions} assertions")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
