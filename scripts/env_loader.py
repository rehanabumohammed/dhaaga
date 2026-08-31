#!/usr/bin/env python3
"""
Read .env into the process environment, on every platform.

Why this exists
---------------
Every script here read `os.environ` and nothing else, and `.env.example` said
"copy to .env and source it". `source` is a Unix shell builtin. PowerShell has
no equivalent, so on Windows the documented workflow simply does not work:

    PS C:\\flutterproject\\dhaaga> python scripts\\migrate.py verify
    migration error: DHAAGA_DB_URL is not set.

The instruction was Linux-shaped, not the scripts. This module makes the
scripts load the file themselves, which works identically in PowerShell, cmd,
bash and CI.

Why not python-dotenv
---------------------
ADR-0002 states the constraint plainly: "No build dependency beyond Python 3
and psql, both present in CI." There is no requirements.txt, no pyproject.toml
and no `pip install` step in .github/workflows/ci.yml. Adding python-dotenv
would introduce the project's first Python dependency, require a manifest and a
CI install step, and make every script fail on a machine that has not run pip -
which is the same class of problem this module exists to remove, moved one step
further away. Sixty lines of standard library is the cheaper, more honest
answer. If the project later grows a real dependency set, this is a reasonable
thing to delete in favour of the library.

Precedence: the real environment always wins over the file
----------------------------------------------------------
A variable already set in the environment is never overwritten. This is not a
detail - it is what keeps the test harnesses correct. They run things like:

    DHAAGA_DB_URL="$SCRATCH_URL" python3 scripts/migrate.py up

If .env overrode that, every scratch-database harness would quietly migrate the
developer's dhaaga_dev instead, and the concurrency and API-session suites would
be testing the wrong database while reporting success. The same rule is what
lets `$env:DHAAGA_DB_URL = <cloud string>` in the deployment runbook point one
command at the cloud without editing any file.

Usage:
    from env_loader import load_env, require_url, require_psql, describe_target
    load_env()
    url = require_url("DHAAGA_DB_URL")

    python scripts/env_loader.py --selftest    prove the parser handles the
                                               files Windows editors produce
"""

from __future__ import annotations

import os
import shutil
import sys
from pathlib import Path
from urllib.parse import urlsplit

REPO_ROOT = Path(__file__).resolve().parent.parent
ENV_FILE = REPO_ROOT / ".env"
EXAMPLE_FILE = REPO_ROOT / ".env.example"

# Hosts that mean "the database on this machine". Anything else is somewhere
# else, and the teardown commands want to know the difference.
LOCAL_HOSTS = {"", "localhost", "127.0.0.1", "::1", "0.0.0.0"}


class EnvError(RuntimeError):
    """A configuration problem the operator can fix, phrased so they can."""


def parse_env(text: str) -> dict[str, str]:
    """
    Parse .env content into a mapping.

    Deliberately forgiving about what Windows editors produce, and deliberately
    strict about one thing: an inline `#` is NOT treated as a comment. A
    database password may legitimately contain one, and silently truncating a
    password at a '#' produces an authentication failure that looks like a
    wrong password rather than a parsing bug. Only a line whose first
    non-blank character is '#' is a comment.
    """
    # Strip a byte-order mark here as well as at read time. Reading with
    # utf-8-sig removes it, but the parser must not depend on its caller having
    # remembered to: a BOM left on the first key produces '﻿DHAAGA_DB_URL',
    # which matches nothing and is invisible in every editor. Caught by the
    # self-test below on its first run.
    text = text.lstrip("﻿")

    values: dict[str, str] = {}
    for raw in text.splitlines():          # handles CRLF as well as LF
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        # `export FOO=bar` - harmless if someone pasted from a Linux guide.
        if line.startswith("export "):
            line = line[len("export "):].lstrip()
        if "=" not in line:
            continue
        # Split on the FIRST '=' only: a connection string can contain more.
        name, _, value = line.partition("=")
        name = name.strip()
        if not name:
            continue
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
            value = value[1:-1]
        values[name] = value
    return values


def load_env(path: Path | None = None, *, override: bool = False) -> list[str]:
    """
    Load .env into os.environ. Returns the names (never the values) of the
    variables it set, so a caller can report what happened without leaking.

    A missing file is not an error: CI sets its variables directly, and so does
    every shell harness.
    """
    env_path = path or ENV_FILE
    if not env_path.is_file():
        return []

    # utf-8-sig strips the byte-order mark that Notepad writes when it saves as
    # "UTF-8". Without this the first key is read as '\ufeffDHAAGA_DB_URL',
    # which never matches anything and is invisible in every editor.
    try:
        text = env_path.read_text(encoding="utf-8-sig")
    except OSError as exc:
        raise EnvError(f"could not read {env_path}: {exc}") from exc

    applied: list[str] = []
    for name, value in parse_env(text).items():
        if override or name not in os.environ:
            os.environ[name] = value
            applied.append(name)
    return applied


def describe_target(url: str) -> str:
    """
    A connection target with the credentials removed, safe to print.

    Everything before '@' is dropped, so a password cannot reach a terminal, a
    log, a screenshot or a chat window.
    """
    try:
        parts = urlsplit(url)
    except ValueError:
        return "(unparseable connection string)"
    host = parts.hostname or "(local socket)"
    port = f":{parts.port}" if parts.port else ""
    name = parts.path.lstrip("/") or "(no database named)"
    return f"{host}{port}/{name}"


def is_local(url: str) -> bool:
    """Whether a connection string points at this machine."""
    try:
        host = urlsplit(url).hostname
    except ValueError:
        return False
    return (host or "") in LOCAL_HOSTS


def require_psql() -> None:
    """
    Every script here shells out to psql. When it is missing, Python raises a
    bare FileNotFoundError with the word 'psql' in it and nothing else, which
    tells a novice on Windows nothing about what to install or that the
    installer does not add it to PATH by default.
    """
    if shutil.which("psql"):
        return
    raise EnvError(
        "psql was not found on PATH, and every script here uses it to talk to PostgreSQL.\n"
        "  On Windows:  winget install PostgreSQL.PostgreSQL.16\n"
        "  The installer does NOT add psql to PATH. Add this folder to your PATH,\n"
        "  adjusting the version number, then open a NEW terminal:\n"
        "      C:\\Program Files\\PostgreSQL\\16\\bin\n"
        "  Check it worked with:  psql --version\n"
        "  On Debian or Ubuntu:  sudo apt-get install postgresql-client-16"
    )


def require_url(name: str = "DHAAGA_DB_URL") -> str:
    """
    Fetch a required connection string, loading .env first, and explain
    concretely how to fix it if it is missing.
    """
    load_env()
    url = os.environ.get(name, "").strip()
    if url:
        return url

    if ENV_FILE.is_file():
        detail = (
            f"{name} is not set, and {ENV_FILE.name} exists but does not define it.\n"
            f"  Open {ENV_FILE} and add a line reading:\n"
            f"      {name}=postgres://postgres@127.0.0.1:5433/dhaaga_dev\n"
            f"  Save it as UTF-8. A byte-order mark and CRLF line endings are both fine."
        )
    else:
        detail = (
            f"{name} is not set and there is no {ENV_FILE.name} file.\n"
            f"  Create one from the template. In PowerShell, from the repository root:\n"
            f"      Copy-Item .env.example .env\n"
            f"  In bash:\n"
            f"      cp .env.example .env\n"
            f"  The scripts read it themselves - PowerShell has no `source`, and none is needed."
        )

    raise EnvError(
        detail
        + "\n\n  To point a single command somewhere else without editing the file:\n"
        "      PowerShell:  $env:DHAAGA_DB_URL = \"postgres://...\"; python scripts\\migrate.py status\n"
        "      bash:        DHAAGA_DB_URL=postgres://... python3 scripts/migrate.py status\n"
        "  A variable already set in the environment always wins over .env."
    )


# ---------------------------------------------------------------------------
# Self-test
# ---------------------------------------------------------------------------
def _selftest() -> int:
    """
    A loader nobody has tried to break is a loader that breaks on somebody's
    machine. These cases are the ones Windows actually produces.
    """
    green, red, dim, reset = "\033[32m", "\033[31m", "\033[2m", "\033[0m"
    passed = failed = 0

    def check(name: str, got, want) -> None:
        nonlocal passed, failed
        if got == want:
            passed += 1
            print(f"{green}ok{reset}    {name}")
        else:
            failed += 1
            print(f"{red}FAIL{reset}  {name}\n      expected {want!r}, got {got!r}")

    # --- parsing -----------------------------------------------------------
    check("a plain assignment", parse_env("A=1"), {"A": "1"})
    check("CRLF line endings, which is what Notepad writes",
          parse_env("A=1\r\nB=2\r\n"), {"A": "1", "B": "2"})
    check("a UTF-8 byte-order mark is not part of the first key",
          parse_env("\ufeffA=1"), {"A": "1"})
    check("whole-line comments and blank lines are skipped",
          parse_env("# note\n\n  # indented note\nA=1"), {"A": "1"})
    check("surrounding whitespace is trimmed",
          parse_env("  A  =  1  "), {"A": "1"})
    check("double quotes are removed", parse_env('A="1"'), {"A": "1"})
    check("single quotes are removed", parse_env("A='1'"), {"A": "1"})
    check("an `export` prefix pasted from a Linux guide is tolerated",
          parse_env("export A=1"), {"A": "1"})
    check("a value containing '=' survives intact",
          parse_env("A=postgres://u:p=q@h:5433/d"), {"A": "postgres://u:p=q@h:5433/d"})
    check("a '#' inside a value is NOT a comment - passwords contain them",
          parse_env("A=postgres://u:pa#ss@h:5433/d"), {"A": "postgres://u:pa#ss@h:5433/d"})
    check("a line with no '=' is ignored rather than crashing",
          parse_env("nonsense\nA=1"), {"A": "1"})
    check("an empty value is preserved as empty", parse_env("A="), {"A": ""})
    check("a later line wins over an earlier one",
          parse_env("A=1\nA=2"), {"A": "2"})

    # --- precedence --------------------------------------------------------
    import tempfile

    with tempfile.TemporaryDirectory() as tmp:
        f = Path(tmp) / ".env"
        f.write_text("DHAAGA_SELFTEST_ONE=from_file\nDHAAGA_SELFTEST_TWO=from_file\n",
                     encoding="utf-8")
        os.environ.pop("DHAAGA_SELFTEST_ONE", None)
        os.environ["DHAAGA_SELFTEST_TWO"] = "from_environment"

        applied = load_env(f)
        check("a variable absent from the environment is taken from the file",
              os.environ.get("DHAAGA_SELFTEST_ONE"), "from_file")
        check("a variable already in the environment is NOT overwritten",
              os.environ.get("DHAAGA_SELFTEST_TWO"), "from_environment")
        check("and the report names only what was actually applied",
              applied, ["DHAAGA_SELFTEST_ONE"])
        check("override=True is available for the caller that wants it",
              (load_env(f, override=True), os.environ.get("DHAAGA_SELFTEST_TWO"))[1],
              "from_file")
        for key in ("DHAAGA_SELFTEST_ONE", "DHAAGA_SELFTEST_TWO"):
            os.environ.pop(key, None)

        check("a missing file is not an error",
              load_env(Path(tmp) / "absent.env"), [])

    # --- redaction ---------------------------------------------------------
    # A deliberately fake credential. It exists so the redaction can be proven
    # to remove it; it is not a real password and matches no real project.
    fake_url = "postgres://fake_user:NOT-A-REAL-PASSWORD@db.example.invalid:5432/postgres"
    shown = describe_target(fake_url)
    check("the target names host, port and database",
          shown, "db.example.invalid:5432/postgres")
    check("and contains no part of the credentials",
          ("NOT-A-REAL-PASSWORD" in shown) or ("fake_user" in shown), False)
    check("a local socket URL is described without inventing a host",
          describe_target("postgres:///dhaaga_dev"), "(local socket)/dhaaga_dev")

    # --- local vs elsewhere ------------------------------------------------
    check("127.0.0.1 is local", is_local("postgres://postgres@127.0.0.1:5433/dhaaga_dev"), True)
    check("localhost is local", is_local("postgres://postgres@localhost:5433/dhaaga_dev"), True)
    check("a socket URL is local", is_local("postgres:///dhaaga_dev"), True)
    check("a remote host is not local", is_local(fake_url), False)

    print()
    if failed:
        print(f"{red}FAILED{reset}  {passed} passed, {failed} failed\n")
        return 1
    print(f"{green}PASSED{reset}  {passed} checks\n")
    return 0


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        raise SystemExit(_selftest())
    # Printing NAMES is safe and occasionally useful; values never are.
    names = load_env()
    print(f"loaded {len(names)} variable(s) from {ENV_FILE}" if names
          else f"nothing loaded (no {ENV_FILE.name}, or every variable was already set)")
