#!/usr/bin/env python3
"""
Export db/migrations to the layout the Supabase CLI expects.

Our migrations are numbered NNNN_name.sql because a reviewer reading the
directory should see the order at a glance. The Supabase CLI wants
<timestamp>_name.sql. Rather than adopt timestamps as the source of truth and
lose that readability, this script produces the CLI layout on demand.

The mapping is deterministic: version NNNN becomes a timestamp derived from a
fixed epoch plus the version number, so re-running produces identical names and
`supabase db push` sees no churn.

Usage: export_supabase.py [--out supabase/migrations]
"""
from __future__ import annotations
import argparse, re, shutil
from datetime import datetime, timedelta, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SRC = REPO / "db" / "migrations"
EPOCH = datetime(2026, 1, 1, tzinfo=timezone.utc)
NAME_RE = re.compile(r"^(\d{4})_([a-z0-9_]+)\.sql$")

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=str(REPO / "supabase" / "migrations"))
    args = ap.parse_args()
    out = Path(args.out)
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)

    count = 0
    for path in sorted(SRC.iterdir()):
        m = NAME_RE.match(path.name)
        if not m:
            continue
        version, name = m.group(1), m.group(2)
        stamp = (EPOCH + timedelta(minutes=int(version))).strftime("%Y%m%d%H%M%S")
        target = out / f"{stamp}_{name}.sql"
        target.write_text(
            f"-- generated from db/migrations/{path.name} by scripts/export_supabase.py\n"
            "-- do not edit here; edit the source migration and re-export\n\n"
            + path.read_text(encoding="utf-8"),
            encoding="utf-8",
        )
        count += 1
    print(f"exported {count} migrations to {out}")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
