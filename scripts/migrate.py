#!/usr/bin/env python3
"""
Dhaaga migration runner.

Dependency-free forward/backward migration runner for PostgreSQL, built on psql.
Chosen over a third-party tool so that P0 has no external build dependency and so
that the exact SQL applied to the database is the SQL held in version control.

Design rules (ADR-0002):
  * Migrations are immutable once applied. The runner stores a checksum and
    refuses to proceed if a previously applied file has changed.
  * Migrations apply in strict version order. A pending migration whose version
    is lower than the highest applied version is an error, not a warning --
    that situation means two branches produced conflicting history.
  * Each migration runs inside a single transaction unless it declares
    "-- dhaaga:no-transaction" on the first line. Either the whole migration
    lands or none of it does.
  * Every migration has a paired rollback script. A migration without one is
    rejected at plan time, not discovered at rollback time.

Usage:
    migrate.py status              show applied and pending migrations
    migrate.py up [--to VERSION]   apply pending migrations
    migrate.py down --to VERSION   roll back to (and including) VERSION
    migrate.py verify              check checksums and pairing without applying
    migrate.py reset               roll back everything (development only)

Environment:
    DHAAGA_DB_URL   postgres connection URL (required)
"""

from __future__ import annotations

import argparse
import hashlib
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

# Load .env ourselves rather than relying on the shell to have sourced it.
# PowerShell has no `source`, so the previous instruction was unusable on
# Windows; see scripts/env_loader.py. A variable already set in the environment
# always wins, which is what keeps `DHAAGA_DB_URL=<scratch> python3 ...` correct
# in the test harnesses.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from env_loader import (EnvError, describe_target, is_local,  # noqa: E402
                        require_psql, require_url)

REPO_ROOT = Path(__file__).resolve().parent.parent
MIGRATIONS_DIR = REPO_ROOT / "db" / "migrations"
ROLLBACK_DIR = REPO_ROOT / "db" / "rollback"

VERSION_RE = re.compile(r"^(\d{4})_([a-z0-9_]+)\.sql$")
NO_TXN_MARKER = "-- dhaaga:no-transaction"

BOOTSTRAP_SQL = """
create schema if not exists dhaaga_meta;

create table if not exists dhaaga_meta.schema_migration (
    version      text        primary key,
    name         text        not null,
    checksum     text        not null,
    applied_at   timestamptz not null default now(),
    applied_by   text        not null default current_user,
    duration_ms  integer
);

comment on table dhaaga_meta.schema_migration is
    'Applied migration history. Managed by scripts/migrate.py; never edited by hand.';
"""


class MigrationError(RuntimeError):
    pass


@dataclass(frozen=True)
class Migration:
    version: str
    name: str
    up_path: Path
    down_path: Path
    checksum: str
    in_transaction: bool

    @property
    def label(self) -> str:
        return f"{self.version}_{self.name}"


def db_url() -> str:
    try:
        require_psql()
        return require_url("DHAAGA_DB_URL")
    except EnvError as exc:
        raise MigrationError(str(exc)) from exc


def psql(sql: str, *, quiet: bool = True, tuples_only: bool = False) -> str:
    """Run SQL through psql with ON_ERROR_STOP so a failure is a failure."""
    cmd = ["psql", db_url(), "-v", "ON_ERROR_STOP=1", "--no-psqlrc"]
    if tuples_only:
        cmd += ["-t", "-A"]
    if quiet:
        cmd += ["-q"]
    cmd += ["-c", sql]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        raise MigrationError(proc.stderr.strip() or proc.stdout.strip())
    return proc.stdout


def psql_file(path: Path, *, single_transaction: bool) -> None:
    cmd = ["psql", db_url(), "-v", "ON_ERROR_STOP=1", "--no-psqlrc", "-q"]
    if single_transaction:
        cmd += ["--single-transaction"]
    cmd += ["-f", str(path)]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        raise MigrationError(f"{path.name}\n{proc.stderr.strip()}")


def checksum(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()[:32]


def discover() -> list[Migration]:
    if not MIGRATIONS_DIR.is_dir():
        raise MigrationError(f"missing migrations directory: {MIGRATIONS_DIR}")

    found: list[Migration] = []
    seen_versions: dict[str, str] = {}

    for path in sorted(MIGRATIONS_DIR.iterdir()):
        if path.name.startswith("."):
            continue
        match = VERSION_RE.match(path.name)
        if not match:
            raise MigrationError(
                f"migration filename does not match NNNN_lower_snake_case.sql: {path.name}"
            )
        version, name = match.group(1), match.group(2)
        if version in seen_versions:
            raise MigrationError(
                f"duplicate migration version {version}: "
                f"{seen_versions[version]} and {path.name}"
            )
        seen_versions[version] = path.name

        down_path = ROLLBACK_DIR / f"{version}_{name}.down.sql"
        if not down_path.exists():
            raise MigrationError(
                f"migration {path.name} has no rollback script at "
                f"db/rollback/{down_path.name}"
            )

        first_line = path.read_text(encoding="utf-8").splitlines()[:1]
        in_txn = not (first_line and first_line[0].strip() == NO_TXN_MARKER)

        found.append(
            Migration(
                version=version,
                name=name,
                up_path=path,
                down_path=down_path,
                checksum=checksum(path),
                in_transaction=in_txn,
            )
        )

    return found


def bootstrap() -> None:
    psql(BOOTSTRAP_SQL)


def applied() -> dict[str, tuple[str, str]]:
    """version -> (name, checksum)"""
    out = psql(
        "select version, name, checksum from dhaaga_meta.schema_migration "
        "order by version",
        tuples_only=True,
    )
    result: dict[str, tuple[str, str]] = {}
    for line in out.strip().splitlines():
        if not line:
            continue
        version, name, csum = line.split("|", 2)
        result[version] = (name, csum)
    return result


def verify(migrations: list[Migration], applied_map: dict[str, tuple[str, str]]) -> None:
    """Refuse to run if history has been rewritten."""
    for migration in migrations:
        record = applied_map.get(migration.version)
        if record is None:
            continue
        name, csum = record
        if name != migration.name:
            raise MigrationError(
                f"migration {migration.version} was applied as '{name}' but the "
                f"file is now '{migration.name}'. Applied migrations are immutable."
            )
        if csum != migration.checksum:
            raise MigrationError(
                f"migration {migration.label} has changed since it was applied "
                f"(checksum {csum} -> {migration.checksum}). Applied migrations are "
                f"immutable: write a new migration instead."
            )

    known = {m.version for m in migrations}
    for version, (name, _) in applied_map.items():
        if version not in known:
            raise MigrationError(
                f"migration {version}_{name} is recorded as applied but its file is "
                f"missing from db/migrations."
            )

    if applied_map:
        highest_applied = max(applied_map)
        out_of_order = [
            m.label
            for m in migrations
            if m.version not in applied_map and m.version < highest_applied
        ]
        if out_of_order:
            raise MigrationError(
                "out-of-order migrations detected (already past version "
                f"{highest_applied}): {', '.join(out_of_order)}. "
                "Renumber them above the highest applied version."
            )


def announce_target() -> None:
    """
    Print the database being acted on, credentials removed. A runner that does
    not say where it is pointing is a runner that migrates the wrong database
    quietly, and on Windows the operator has no `echo $DHAAGA_DB_URL` habit to
    fall back on.
    """
    url = db_url()
    where = "local" if is_local(url) else "REMOTE"
    print(f"  target: {describe_target(url)}  [{where}]")


def cmd_status(args: argparse.Namespace) -> int:
    announce_target()
    migrations = discover()
    bootstrap()
    applied_map = applied()
    print(f"{'':2}{'VERSION':<9}{'NAME':<44}STATUS")
    for migration in migrations:
        record = applied_map.get(migration.version)
        if record is None:
            status = "pending"
            mark = " "
        elif record[1] != migration.checksum:
            status = "APPLIED (checksum mismatch)"
            mark = "!"
        else:
            status = "applied"
            mark = "✓"
        print(f"{mark:2}{migration.version:<9}{migration.name:<44}{status}")
    pending = sum(1 for m in migrations if m.version not in applied_map)
    print(f"\n{len(migrations)} migrations, {pending} pending")
    return 0


def cmd_verify(args: argparse.Namespace) -> int:
    announce_target()
    migrations = discover()
    bootstrap()
    verify(migrations, applied())
    print(f"verify: OK - {len(migrations)} migrations, checksums and rollback pairs intact")
    return 0


def cmd_up(args: argparse.Namespace) -> int:
    announce_target()
    migrations = discover()
    bootstrap()
    applied_map = applied()
    verify(migrations, applied_map)

    pending = [m for m in migrations if m.version not in applied_map]
    if args.to:
        pending = [m for m in pending if m.version <= args.to]

    if not pending:
        print("up: nothing to do")
        return 0

    for migration in pending:
        print(f"  applying {migration.label} ...", end=" ", flush=True)
        psql_file(migration.up_path, single_transaction=migration.in_transaction)
        psql(
            "insert into dhaaga_meta.schema_migration (version, name, checksum) "
            f"values ('{migration.version}', '{migration.name}', '{migration.checksum}')"
        )
        print("ok")

    print(f"up: applied {len(pending)} migration(s)")
    return 0


def assert_teardown_target_is_safe(args: argparse.Namespace) -> None:
    """
    `down` and `reset` drop application objects. Getting them pointed at a
    remote database by an environment variable left over from a previous
    command is the mistake that costs a day, and it is exactly the mistake the
    deployment runbook invites: it tells the operator to set DHAAGA_DB_URL to
    the cloud connection string for one step. This refuses rather than trusting
    them to have put it back.
    """
    url = db_url()
    if is_local(url) or getattr(args, "allow_remote", False):
        return
    raise MigrationError(
        f"refusing to tear down a database that is not on this machine: {describe_target(url)}\n"
        "  `down` and `reset` drop every application object. If DHAAGA_DB_URL is\n"
        "  still pointing at the cloud from an earlier command, set it back first:\n"
        "      PowerShell:  $env:DHAAGA_DB_URL = \"postgres://postgres@127.0.0.1:5433/dhaaga_dev\"\n"
        "      bash:        export DHAAGA_DB_URL=postgres://postgres@127.0.0.1:5433/dhaaga_dev\n"
        "  If you genuinely mean to tear that database down, pass --allow-remote."
    )


def cmd_down(args: argparse.Namespace) -> int:
    assert_teardown_target_is_safe(args)
    announce_target()
    migrations = discover()
    bootstrap()
    applied_map = applied()
    verify(migrations, applied_map)

    target = args.to
    to_revert = [
        m
        for m in reversed(migrations)
        if m.version in applied_map and m.version >= target
    ]
    if not to_revert:
        print("down: nothing to do")
        return 0

    for migration in to_revert:
        print(f"  reverting {migration.label} ...", end=" ", flush=True)
        psql_file(migration.down_path, single_transaction=True)
        psql(
            "delete from dhaaga_meta.schema_migration "
            f"where version = '{migration.version}'"
        )
        print("ok")

    print(f"down: reverted {len(to_revert)} migration(s)")
    return 0


def cmd_reset(args: argparse.Namespace) -> int:
    assert_teardown_target_is_safe(args)
    args.to = "0000"
    return cmd_down(args)


def main() -> int:
    parser = argparse.ArgumentParser(description="Dhaaga migration runner")
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("status").set_defaults(func=cmd_status)
    sub.add_parser("verify").set_defaults(func=cmd_verify)

    up = sub.add_parser("up")
    up.add_argument("--to", help="apply up to and including this version")
    up.set_defaults(func=cmd_up)

    down = sub.add_parser("down")
    down.add_argument("--to", required=True, help="revert down to and including this version")
    down.add_argument("--allow-remote", action="store_true",
                      help="permit tearing down a database that is not on this machine")
    down.set_defaults(func=cmd_down)

    reset = sub.add_parser("reset")
    reset.add_argument("--allow-remote", action="store_true",
                       help="permit tearing down a database that is not on this machine")
    reset.set_defaults(func=cmd_reset)

    args = parser.parse_args()
    try:
        return args.func(args)
    except MigrationError as exc:
        print(f"\nmigration error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
