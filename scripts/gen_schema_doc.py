#!/usr/bin/env python3
"""
Generate docs/schema.md from the live database.

Generated rather than hand-written so it cannot drift from the schema it claims
to describe (WP-12). Run it after any migration; CI checks that the committed
copy matches what the current schema produces.

Usage:
    gen_schema_doc.py            write docs/schema.md
    gen_schema_doc.py --check    exit non-zero if the committed copy is stale

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
from env_loader import EnvError, require_url  # noqa: E402

REPO = Path(__file__).resolve().parent.parent
OUT = REPO / "docs" / "schema.md"

# Cluster membership follows the blueprint's §2 sections, so the generated
# document reads in the same order as the architecture it implements.
CLUSTERS = [
    ("2.1 Tenancy, identity, audit", [
        "business", "branch", "app_user", "permission", "role", "role_permission",
        "user_branch_role", "device", "number_series", "number_lease", "number_void",
        "audit_event"]),
    ("2.2 Configuration, localisation, tax", [
        "locale", "translation", "config_setting", "config_version",
        "config_branch_override", "reason_code", "tax_profile", "tax_code", "tax_rate",
        "tax_rate_component", "price_list", "notification_template", "validation_signoff"]),
    ("2.3 Customers, households, measurements", [
        "household", "customer", "household_member", "customer_contact",
        "duplicate_candidate", "customer_merge", "garment_type", "style_option_group",
        "style_option", "price_list_item", "measurement_template", "template_field",
        "measurement_profile", "measurement_revision", "measurement_value",
        "measurement_snapshot", "attachment"]),
    ("2.4 Orders, production, capacity", [
        "workflow_template", "workflow_stage", "priority_class", "branch_calendar",
        "calendar_exception", "staff_capacity", "staff_skill", "sales_order",
        "order_item", "garment", "garment_style_option", "job_card", "job_card_garment",
        "production_task", "trial_event", "alteration", "date_override",
        "delivery_note", "delivery_line"]),
    ("2.5 Finance", [
        "account", "accounting_period", "journal_entry", "journal_line", "cash_session",
        "invoice", "invoice_line", "credit_note", "payment_mode", "payment",
        "payment_allocation", "supplier", "purchase_bill", "purchase_bill_line",
        "expense", "wage_scheme", "wage_rate", "wage_payout", "wage_entry",
        "staff_advance"]),
    ("2.6 Inventory and customer material", [
        "stock_item", "stock_movement", "stock_balance", "stock_transfer",
        "stock_transfer_line", "customer_material", "customer_material_movement"]),
]

SPINE = {"id", "business_id", "created_at", "created_by", "updated_at",
         "updated_by", "deleted_at", "row_version"}


def q(sql: str) -> list[list[str]]:
    try:
        url = require_url("DHAAGA_DB_URL")
    except EnvError as exc:
        print(f"\nconfiguration error: {exc}\n", file=sys.stderr)
        raise SystemExit(2)
    proc = subprocess.run(
        ["psql", url, "-v", "ON_ERROR_STOP=1", "--no-psqlrc", "-t", "-A", "-F", "\x1f", "-c", sql],
        capture_output=True, text=True, encoding="utf-8")
    if proc.returncode != 0:
        print(proc.stderr.strip(), file=sys.stderr)
        raise SystemExit(1)
    return [line.split("\x1f") for line in proc.stdout.strip().splitlines() if line]


def build() -> str:
    comments = {r[0]: r[1] for r in q(
        "select c.relname, coalesce(obj_description(c.oid,'pg_class'),'') "
        "from pg_class c join pg_namespace n on n.oid=c.relnamespace "
        "where n.nspname='public' and c.relkind='r'")}

    cols: dict[str, list[tuple[str, str, str, str]]] = {}
    for tbl, name, typ, notnull, default in q(
            "select c.relname, a.attname, format_type(a.atttypid,a.atttypmod), "
            "  case when a.attnotnull then 'not null' else '' end, "
            "  coalesce(pg_get_expr(d.adbin,d.adrelid),'') "
            "from pg_class c join pg_namespace n on n.oid=c.relnamespace "
            "join pg_attribute a on a.attrelid=c.oid "
            "left join pg_attrdef d on d.adrelid=c.oid and d.adnum=a.attnum "
            "where n.nspname='public' and c.relkind='r' and a.attnum>0 and not a.attisdropped "
            "order by c.relname, a.attnum"):
        cols.setdefault(tbl, []).append((name, typ, notnull, default))

    fks: dict[str, list[str]] = {}
    for tbl, defn in q(
            "select c.conrelid::regclass::text, pg_get_constraintdef(c.oid) "
            "from pg_constraint c join pg_namespace n on n.oid=c.connamespace "
            "where n.nspname='public' and c.contype='f' order by 1,2"):
        fks.setdefault(tbl, []).append(defn)

    checks: dict[str, list[str]] = {}
    for tbl, name, defn in q(
            "select c.conrelid::regclass::text, c.conname, pg_get_constraintdef(c.oid) "
            "from pg_constraint c join pg_namespace n on n.oid=c.connamespace "
            "where n.nspname='public' and c.contype in ('c','x') order by 1,2"):
        checks.setdefault(tbl, []).append(f"`{name}` — {defn}")

    known = {t for _, tables in CLUSTERS for t in tables}
    missing = sorted(set(comments) - known)

    out: list[str] = []
    out.append("# Dhaaga — database schema\n\n")
    out.append("**Generated by `scripts/gen_schema_doc.py`. Do not edit by hand.**\n\n")
    out.append(
        "Every table carries the standard spine (ADR-0004) — `id`, `business_id`, "
        "`created_at`, `created_by`, `updated_at`, `updated_by`, `deleted_at`, "
        "`row_version` — which is omitted from the column lists below. Transactional "
        "tables additionally carry `branch_id`.\n\n")
    out.append(f"**{len(comments)} tables** across six clusters.\n")

    for title, tables in CLUSTERS:
        out.append(f"\n## {title}\n")
        for tbl in tables:
            if tbl not in comments:
                continue
            out.append(f"\n### `{tbl}`\n\n")
            if comments[tbl]:
                out.append(f"{comments[tbl]}\n")
            body = [c for c in cols.get(tbl, []) if c[0] not in SPINE]
            if body:
                out.append("\n| column | type | |")
                out.append("\n|---|---|---|")
                for name, typ, notnull, default in body:
                    extra = notnull
                    if default and not default.startswith("nextval"):
                        extra = (extra + " · " if extra else "") + f"default `{default}`"
                    out.append(f"\n| `{name}` | {typ} | {extra} |")
                out.append("\n")
            if fks.get(tbl):
                out.append("\nReferences: " + ", ".join(
                    f"`{d.split('REFERENCES ')[1].split('(')[0]}`" for d in fks[tbl]) + "\n")
            if checks.get(tbl):
                out.append("\nConstraints:\n\n")
                for c in checks[tbl]:
                    out.append(f"- {c}\n")

    if missing:
        out.append("\n## Not yet assigned to a cluster\n")
        out.append("\n" + ", ".join(f"`{t}`" for t in missing) + "\n")

    return "".join(out)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()
    content = build()
    if args.check:
        if not OUT.exists() or OUT.read_text(encoding="utf-8") != content:
            print("docs/schema.md is stale - run scripts/gen_schema_doc.py", file=sys.stderr)
            return 1
        print("docs/schema.md is current")
        return 0
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(content, encoding="utf-8")
    print(f"wrote {OUT.relative_to(REPO)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
