-- Dhaaga test assertions.
-- Loaded into every test transaction by scripts/test.py and rolled back with it.
-- Never applied by a migration: these functions must not exist in production.

create schema if not exists dhaaga_test;

create or replace function dhaaga_test.ok(condition boolean, name text)
returns void language plpgsql as $$
begin
    if condition is not true then
        raise exception 'assertion failed: %', name using errcode = 'triggered_action_exception';
    end if;
    raise notice 'ok - %', name;
end $$;

create or replace function dhaaga_test.eq(actual anyelement, expected anyelement, name text)
returns void language plpgsql as $$
begin
    if actual is distinct from expected then
        raise exception 'assertion failed: % (expected %, got %)', name, expected, actual
            using errcode = 'triggered_action_exception';
    end if;
    raise notice 'ok - %', name;
end $$;

-- Asserts that a statement fails. Optionally pins the SQLSTATE, so a test that
-- expects a permission error does not pass because of a typo in a column name.
create or replace function dhaaga_test.throws(stmt text, name text, expect_sqlstate text default null)
returns void language plpgsql as $$
declare
    got_state text;
begin
    begin
        execute stmt;
    exception when others then
        got_state := SQLSTATE;
        if expect_sqlstate is not null and got_state <> expect_sqlstate then
            raise exception 'assertion failed: % (expected SQLSTATE %, got % - %)',
                name, expect_sqlstate, got_state, SQLERRM
                using errcode = 'triggered_action_exception';
        end if;
        raise notice 'ok - %', name;
        return;
    end;
    raise exception 'assertion failed: % (statement succeeded but should have failed)', name
        using errcode = 'triggered_action_exception';
end $$;

create or replace function dhaaga_test.lives(stmt text, name text)
returns void language plpgsql as $$
begin
    execute stmt;
    raise notice 'ok - %', name;
exception when others then
    raise exception 'assertion failed: % (statement failed: %)', name, SQLERRM
        using errcode = 'triggered_action_exception';
end $$;

-- Drops every scrap of caller identity, which is the state a migration, a seed
-- or a restore runs in. Fixture setup between cases must use it: since WP-7 an
-- administrative write demands a caller who holds the permission, so a fixture
-- left carrying the previous case's token is refused - correctly, and
-- confusingly, at a line that has nothing to do with what is being tested.
create or replace function dhaaga_test.as_nobody()
returns void language plpgsql as $$
begin
    perform set_config('request.jwt.claims', '', true);
    perform set_config('app.actor_id', '', true);
end $$;

-- Convenience: does a relation exist in the application schema?
create or replace function dhaaga_test.table_exists(tbl text)
returns boolean language sql stable as $$
    select exists (
        select 1 from information_schema.tables
        where table_schema = 'public' and table_name = tbl and table_type = 'BASE TABLE'
    );
$$;

create or replace function dhaaga_test.column_exists(tbl text, col text)
returns boolean language sql stable as $$
    select exists (
        select 1 from information_schema.columns
        where table_schema = 'public' and table_name = tbl and column_name = col
    );
$$;

-- The isolation suite runs assertions while acting as the `authenticated` role,
-- which is the whole point of it: testing as the table owner would prove
-- nothing, because an owner bypasses row-level security. That role therefore
-- needs to be able to call these helpers. The grant is safe because this schema
-- and everything in it is created inside the test transaction and rolled back
-- with it - it never exists in a real database.
grant usage on schema dhaaga_test to public;
grant execute on all functions in schema dhaaga_test to public;
