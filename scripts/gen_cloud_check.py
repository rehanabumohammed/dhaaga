#!/usr/bin/env python3
"""
Generate db/verify/cloud_postcheck.sql from the verified local schema.

The post-check compares a deployed database against the schema that has passed
locally. Its expected values must therefore be generated, not typed: a
hand-maintained expectation drifts from the schema and starts reporting false
failures, which is how a verification script stops being read.

Usage:
    gen_cloud_check.py          write db/verify/cloud_postcheck.sql
    gen_cloud_check.py --check  exit non-zero if the committed copy is stale

Environment:
    DHAAGA_DB_URL   the VERIFIED LOCAL database, not the cloud one
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
OUT = REPO / "db" / "verify" / "cloud_postcheck.sql"

FINGERPRINT_SQL = """
with cols as (
    select table_schema||'.'||table_name||'.'||column_name||':'||data_type||
           coalesce(':'||character_maximum_length::text,'')||':'||is_nullable as sig
    from information_schema.columns where table_schema in ('public','app'))
select md5(string_agg(sig, chr(10) order by sig)) from cols;"""

# Functions are where WP-5 and WP-6 put the enforcement, and their privileges
# are as load-bearing as the policies. A deployment that lands the bodies but
# loses the grants would pass every table-shaped check, so the fingerprint
# covers the signature, the SECURITY DEFINER flag, whether search_path is
# pinned, and who may execute.
FUNCTION_FINGERPRINT_SQL = """
select md5(string_agg(sig, chr(10) order by sig))
from (
    select p.proname||'('||pg_get_function_identity_arguments(p.oid)||')'
           ||':secdef='||p.prosecdef::text
           ||':pinned='||(p.proconfig is not null
                          and exists (select 1 from unnest(p.proconfig) c
                                       where c like 'search_path=%'))::text
           ||':authenticated='||has_function_privilege('authenticated', p.oid, 'EXECUTE')::text
           as sig
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app'
) s;"""


def q(sql: str) -> str:
    try:
        url = require_url("DHAAGA_DB_URL")
    except EnvError as exc:
        print(f"\nconfiguration error: {exc}\n", file=sys.stderr)
        raise SystemExit(2)
    r = subprocess.run(["psql", url, "-tA", "--no-psqlrc", "-c", sql],
                       capture_output=True, text=True)
    if r.returncode:
        print(r.stderr.strip(), file=sys.stderr)
        raise SystemExit(1)
    return r.stdout.strip()


def build() -> str:
    tables = q("select string_agg(quote_literal(relname::text), ',' order by relname) "
               "from pg_class c join pg_namespace n on n.oid=c.relnamespace "
               "where n.nspname='public' and c.relkind='r';")
    n_tables = q("select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace "
                 "where n.nspname='public' and c.relkind='r';")
    n_pol = q("select count(*) from pg_policies where schemaname='public';")
    fp = q(FINGERPRINT_SQL)
    n_fn = q("select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace "
             "where n.nspname='app';")
    fn_fp = q(FUNCTION_FINGERPRINT_SQL)

    return f"""-- Dhaaga · cloud post-deployment verification
--
-- Run against the cloud project AFTER `supabase db push`, in the SQL editor or
-- with psql. It answers, mechanically, what must be true before a deployment
-- can be called good.
--
-- Every row carries a verdict, and FAIL rows sort to the top. If any row reads
-- FAIL: stop, run nothing else against the project, and report the output.
--
-- Expected values are generated from the verified local schema by
-- scripts/gen_cloud_check.py. Regenerate after any migration, or this file will
-- report a false failure and stop being trusted.

with expected as (
    select
        {n_tables}::int         as table_count,
        {n_pol}::int            as policy_count,
        '{fp}'::text            as schema_fingerprint,
        {n_fn}::int             as function_count,
        '{fn_fp}'::text         as function_fingerprint,
        array[{tables}]::text[] as table_names
),
actual as (
    select
        (select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
         where n.nspname = 'public' and c.relkind = 'r')::int as table_count,
        (select count(*) from pg_policies where schemaname = 'public')::int as policy_count,
        (select md5(string_agg(sig, chr(10) order by sig)) from (
            select table_schema||'.'||table_name||'.'||column_name||':'||data_type||
                   coalesce(':'||character_maximum_length::text,'')||':'||is_nullable as sig
            from information_schema.columns where table_schema in ('public','app')) s
        ) as schema_fingerprint,
        (select coalesce(array_agg(c.relname::text order by c.relname), array[]::text[])
         from pg_class c join pg_namespace n on n.oid = c.relnamespace
         where n.nspname = 'public' and c.relkind = 'r') as table_names,
        (select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
         where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity)::int as tables_without_rls,
        (select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
         where n.nspname = 'public' and c.relkind = 'r'
           and not exists (select 1 from pg_policy p where p.polrelid = c.oid))::int as tables_without_policy,
        (select count(*) from information_schema.role_table_grants
         where grantee = 'anon' and table_schema = 'public')::int as anon_grants,
        (select coalesce(string_agg(distinct privilege_type, ', ' order by privilege_type), '(none)')
         from information_schema.role_table_grants
         where grantee = 'authenticated' and table_schema = 'public' and table_name = 'audit_event'
        ) as audit_grants,
        (select coalesce(string_agg(extname, ', ' order by extname), '(none)')
         from pg_extension where extname in ('pgcrypto','pg_trgm','btree_gist')) as extensions,
        (select count(*) from information_schema.schemata
         where schema_name = 'supabase_migrations')::int as cli_migration_schema,
        (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'app')::int as function_count,
        (select md5(string_agg(sig, chr(10) order by sig)) from (
            select p.proname||'('||pg_get_function_identity_arguments(p.oid)||')'
                   ||':secdef='||p.prosecdef::text
                   ||':pinned='||(p.proconfig is not null
                                  and exists (select 1 from unnest(p.proconfig) c
                                               where c like 'search_path=%'))::text
                   ||':authenticated='||has_function_privilege('authenticated', p.oid, 'EXECUTE')::text
                   as sig
            from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app') s
        ) as function_fingerprint,
        (select coalesce(string_agg(p.proname, ', ' order by p.proname), '(none)')
         from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'app'
           and (has_function_privilege('public', p.oid, 'EXECUTE')
                or has_function_privilege('anon', p.oid, 'EXECUTE'))) as functions_exposed,
        (select coalesce(string_agg(p.proname, ', ' order by p.proname), '(none)')
         from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'app' and p.prosecdef
           and (p.proconfig is null
                or not exists (select 1 from unnest(p.proconfig) c
                                where c like 'search_path=%'))) as functions_unpinned
),
diff as (
    select array(select unnest((select table_names from actual))
                 except select unnest((select table_names from expected))) as unexpected,
           array(select unnest((select table_names from expected))
                 except select unnest((select table_names from actual))) as missing
)
select * from (
    values
    ('migrations · CLI migration history present',
     '1', (select cli_migration_schema::text from actual),
     case when (select cli_migration_schema from actual) = 1 then 'PASS' else 'FAIL' end),

    ('schema · table count',
     (select table_count::text from expected), (select table_count::text from actual),
     case when (select table_count from expected) = (select table_count from actual) then 'PASS' else 'FAIL' end),

    ('schema · unexpected tables',
     'none', coalesce(nullif(array_to_string((select unexpected from diff), ', '), ''), 'none'),
     case when cardinality((select unexpected from diff)) = 0 then 'PASS' else 'FAIL' end),

    ('schema · missing tables',
     'none', coalesce(nullif(array_to_string((select missing from diff), ', '), ''), 'none'),
     case when cardinality((select missing from diff)) = 0 then 'PASS' else 'FAIL' end),

    ('schema · fingerprint matches verified local schema',
     substring((select schema_fingerprint from expected) for 12),
     substring((select schema_fingerprint from actual) for 12),
     case when (select schema_fingerprint from expected) = (select schema_fingerprint from actual)
          then 'PASS' else 'FAIL' end),

    ('rls · tables without row-level security',
     '0', (select tables_without_rls::text from actual),
     case when (select tables_without_rls from actual) = 0 then 'PASS' else 'FAIL' end),

    ('rls · tables without a policy',
     '0', (select tables_without_policy::text from actual),
     case when (select tables_without_policy from actual) = 0 then 'PASS' else 'FAIL' end),

    ('rls · policy count',
     (select policy_count::text from expected), (select policy_count::text from actual),
     case when (select policy_count from expected) = (select policy_count from actual) then 'PASS' else 'FAIL' end),

    ('functions · app schema function count',
     (select function_count::text from expected), (select function_count::text from actual),
     case when (select function_count from expected) = (select function_count from actual) then 'PASS' else 'FAIL' end),

    ('functions · signature, SECURITY DEFINER and grant fingerprint',
     substring((select function_fingerprint from expected) for 12),
     substring((select function_fingerprint from actual) for 12),
     case when (select function_fingerprint from expected) = (select function_fingerprint from actual)
          then 'PASS' else 'FAIL' end),

    ('functions · executable by PUBLIC or anon',
     'none', (select functions_exposed from actual),
     case when (select functions_exposed from actual) = '(none)' then 'PASS' else 'FAIL' end),

    ('functions · SECURITY DEFINER without a pinned search_path',
     'none', (select functions_unpinned from actual),
     case when (select functions_unpinned from actual) = '(none)' then 'PASS' else 'FAIL' end),

    ('exposure · anonymous role table privileges',
     '0', (select anon_grants::text from actual),
     case when (select anon_grants from actual) = 0 then 'PASS' else 'FAIL' end),

    ('exposure · audit trail privileges for authenticated',
     'INSERT, SELECT', (select audit_grants from actual),
     case when (select audit_grants from actual) = 'INSERT, SELECT' then 'PASS' else 'FAIL' end),

    ('extensions · required extensions present',
     'btree_gist, pg_trgm, pgcrypto', (select extensions from actual),
     case when (select extensions from actual) = 'btree_gist, pg_trgm, pgcrypto' then 'PASS' else 'FAIL' end)
) as t(check_name, expected, actual, verdict)
order by case when verdict = 'FAIL' then 0 else 1 end, check_name;
"""


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()
    content = build()
    if args.check:
        if not OUT.exists() or OUT.read_text(encoding="utf-8") != content:
            print("db/verify/cloud_postcheck.sql is stale - run scripts/gen_cloud_check.py",
                  file=sys.stderr)
            return 1
        print("db/verify/cloud_postcheck.sql is current")
        return 0
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(content, encoding="utf-8")
    print(f"wrote {OUT.relative_to(REPO)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
