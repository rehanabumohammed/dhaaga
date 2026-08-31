#!/usr/bin/env python3
"""
Load development seed data.

Every seed file is idempotent: rows carry deterministic ids and every insert is
`on conflict (id) do nothing`. Running this twice changes nothing, which is what
makes it safe in CI and safe to re-run after a partial failure.

Usage:
    seed.py            load every file in db/seed in order
    seed.py --verify   load, then re-load, and confirm nothing changed

Environment:
    DHAAGA_DB_URL   postgres connection URL (required)
"""
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

# Load .env ourselves rather than relying on the shell to have sourced it.
# PowerShell has no `source`, so the previous instruction was unusable on
# Windows; see scripts/env_loader.py. A variable already set in the environment
# always wins, which is what keeps `DHAAGA_DB_URL=<scratch> python3 ...` correct
# in the test harnesses.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from env_loader import EnvError, describe_target, require_psql, require_url  # noqa: E402

REPO = Path(__file__).resolve().parent.parent
SEED_DIR = REPO / "db" / "seed"

COUNT_SQL = """
select coalesce(sum(n), 0) from (
    select count(*) as n from business union all
    select count(*) from branch union all
    select count(*) from app_user union all
    select count(*) from role union all
    select count(*) from permission union all
    select count(*) from role_permission union all
    select count(*) from user_branch_role union all
    select count(*) from account union all
    select count(*) from payment_mode union all
    select count(*) from reason_code union all
    select count(*) from garment_type union all
    select count(*) from template_field union all
    select count(*) from workflow_stage union all
    select count(*) from style_option union all
    select count(*) from config_setting union all
    select count(*) from number_series union all
    select count(*) from audit_reason_requirement
) t;
"""


def db_url() -> str:
    try:
        require_psql()
        return require_url("DHAAGA_DB_URL")
    except EnvError as exc:
        print(f"\nconfiguration error: {exc}\n", file=sys.stderr)
        raise SystemExit(2)


def run_sql(sql: str) -> str:
    proc = subprocess.run(
        ["psql", db_url(), "-v", "ON_ERROR_STOP=1", "--no-psqlrc", "-t", "-A", "-c", sql],
        capture_output=True, text=True,
    )
    if proc.returncode != 0:
        print(proc.stderr.strip(), file=sys.stderr)
        raise SystemExit(1)
    return proc.stdout.strip()


def load() -> int:
    files = sorted(SEED_DIR.glob("*.sql"))
    if not files:
        print(f"no seed files in {SEED_DIR}", file=sys.stderr)
        return 2
    for path in files:
        print(f"  loading {path.name} ...", end=" ", flush=True)
        proc = subprocess.run(
            ["psql", db_url(), "-v", "ON_ERROR_STOP=1", "--no-psqlrc", "-q",
             "--single-transaction", "-f", str(path)],
            capture_output=True, text=True,
        )
        if proc.returncode != 0:
            print("FAILED")
            print(proc.stderr.strip(), file=sys.stderr)
            return 1
        print("ok")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--verify", action="store_true",
                    help="load twice and confirm the second load changes nothing")
    args = ap.parse_args()

    # The seed creates a fictional business. It belongs in development and
    # staging and must never reach production, so the target is named before
    # anything is written - credentials removed.
    print(f"  target: {describe_target(db_url())}")

    rc = load()
    if rc != 0:
        return rc
    first = run_sql(COUNT_SQL)
    print(f"seed: {first} rows across the seeded tables")

    if args.verify:
        print("re-loading to verify idempotency ...")
        rc = load()
        if rc != 0:
            return rc
        second = run_sql(COUNT_SQL)
        if first != second:
            print(f"NOT IDEMPOTENT: {first} rows before, {second} after", file=sys.stderr)
            return 1
        print(f"idempotent: {second} rows, unchanged by a second load")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
