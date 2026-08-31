-- 0010 · Fail closed on future tables
--
-- Found while preparing the first cloud deployment.
--
-- Supabase configures ALTER DEFAULT PRIVILEGES so that tables created in
-- `public` by the `postgres` role are automatically granted to `anon` and
-- `authenticated`. That is a sensible default for a hand-built project and a
-- hazard for this one: every migration in P1 and beyond that creates a table
-- would have it granted to the anonymous role at the moment of creation, and
-- would stay that way until somebody remembered to revoke it.
--
-- Migration 0009 revokes those grants for the tables that existed then. This
-- migration changes the default for tables that do not exist yet, so the
-- exposure cannot reappear by omission.
--
-- The trade is deliberate: a new table is now unreachable by the application
-- until its migration grants access explicitly. That fails loudly during
-- development, which is the right direction to fail in. Silent exposure of a
-- customer's measurements to an anonymous caller is not.

do $$
begin
    if exists (select 1 from pg_roles where rolname = 'anon') then
        execute 'alter default privileges in schema public revoke all on tables from anon';
        execute 'alter default privileges in schema public revoke all on sequences from anon';
        execute 'alter default privileges in schema public revoke all on functions from anon';
    end if;
    if exists (select 1 from pg_roles where rolname = 'authenticated') then
        execute 'alter default privileges in schema public revoke all on tables from authenticated';
    end if;
end $$;

-- The same, for anything the `postgres` role creates -- which is what the
-- Supabase CLI connects as when it applies a migration.
do $$
begin
    if exists (select 1 from pg_roles where rolname = 'postgres')
       and exists (select 1 from pg_roles where rolname = 'anon') then
        execute 'alter default privileges for role postgres in schema public revoke all on tables from anon';
        execute 'alter default privileges for role postgres in schema public revoke all on tables from authenticated';
    end if;
end $$;

comment on schema public is
    'Application tables. Every one carries row-level security and at least one policy; anon holds no privilege on any of them. New tables are NOT granted by default (migration 0010) - each migration must grant access to `authenticated` explicitly.';
