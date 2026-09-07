-- 0018 · Synchronization change cursor, and the deletion invariant it depends on (WP-8)
--
-- WP-8 synchronizes authoritative CURRENT STATE, not an event log. A client
-- asks "what has changed since the last time I asked", and the database must be
-- able to answer that question without ever losing a row.
--
-- The cursor is a PostgreSQL MVCC snapshot, not a sequence. A bigserial cursor
-- is wrong here, and not marginally so: allocation order, statement order,
-- transaction order and COMMIT order are four different things. A long
-- transaction can allocate sequence value 1, a short one can allocate 2 and
-- commit first, and a client that has read up to 2 will never see 1. Snapshot
-- fencing has no such gap -- pg_visible_in_snapshot() answers "was this
-- transaction committed as far as that reader was concerned", which is exactly
-- the question a change feed needs to ask.
--
-- So every synchronization-managed row carries the transaction that last wrote
-- it, stamped by the server:
--
--     change_xid xid8   -- pg_current_xact_id() at write time
--
-- and a later pull is expressed as
--
--     where change_xid is not null
--       and change_xid >= pg_snapshot_xmin(:s_prev)     -- index-usable bounds,
--       and change_xid <  pg_snapshot_xmax(:s_now)      -- logically implied
--       and not pg_visible_in_snapshot(change_xid, :s_prev)
--       and     pg_visible_in_snapshot(change_xid, :s_now)
--
-- The two range bounds are redundant with the visibility predicates and are
-- there for one reason: pg_visible_in_snapshot() is opaque to the planner, so
-- without them the partial index below could not be used at all.
--
-- No central change-log table is introduced. audit_event is the audit and
-- history mechanism (BR-13) and stays that way; it is not the synchronization
-- feed, and repurposing it would be wrong on two counts -- it watches 46 tables
-- rather than all 90, and its primary key is a uuid, which orders nothing.
--
-- ---------------------------------------------------------------------------
-- C1, the deletion invariant
-- ---------------------------------------------------------------------------
-- A state-based feed can only report a row it can still see. A hard DELETE
-- therefore removes a row from the feed silently: the client keeps its copy
-- forever, and no pull will ever contradict it. That is data corruption with no
-- error message, so it is closed here:
--
--   Every authoritative deletion of a synchronization-managed entity must
--   produce a synchronization-visible removal.
--
-- Soft deletion already satisfies this. `deleted_at` is set by an UPDATE, the
-- standard trigger stamps a fresh change_xid, and the removal travels to the
-- client as an ordinary change. So the invariant is enforced by making hard
-- deletion impossible through every application path:
--
--   * `authenticated` loses the DELETE privilege outright.
--   * `service_role` loses DELETE and TRUNCATE. It is not a table owner, so a
--     revoke is decisive; it holds BYPASSRLS, which bypasses row-level security
--     and no table privilege at all.
--   * A BEFORE DELETE trigger on all 90 tables refuses the row. This is the
--     part that matters, because a SECURITY DEFINER function runs as its owner
--     and a privilege revoke would not stop one. A trigger stops it.
--
-- Owner and superuser maintenance stays outside this invariant, exactly as it
-- does for audit_event (0011) and the ledger (0012): the owner can disable the
-- trigger, and doing so is a schema change and therefore visible. That is the
-- same trade those two migrations already made, and this one does not widen it.

-- ===========================================================================
-- Preconditions
-- ===========================================================================
-- xid8, pg_current_xact_id() and pg_visible_in_snapshot() are PostgreSQL 13
-- and later. ADR-0001 pins 16 locally and in production; asserting it here
-- means a wrong server fails at migration time rather than at first sync.
do $$
begin
    if current_setting('server_version_num')::int < 130000 then
        raise exception 'migration 0018 requires PostgreSQL 13 or later (xid8); this server is %',
            current_setting('server_version')
            using errcode = 'feature_not_supported';
    end if;
end $$;

-- The synchronization-managed set is every application table in `public`, and
-- the standard row spine is what makes a table synchronizable at all -- without
-- app.touch_row() attached there is nothing to stamp change_xid. The two must
-- agree, so the migration checks that they do rather than assuming it.
do $$
declare
    n_tables   integer;
    n_spined   integer;
    missing    text;
begin
    select count(*) into n_tables
      from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind = 'r';

    select count(*) into n_spined
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind = 'r'
       and exists (
           select 1 from pg_trigger t
           where t.tgrelid = c.oid and not t.tgisinternal
             and t.tgname = '00_touch_row_' || c.relname
       );

    if n_tables <> n_spined then
        select string_agg(c.relname, ', ' order by c.relname) into missing
          from pg_class c join pg_namespace n on n.oid = c.relnamespace
         where n.nspname = 'public' and c.relkind = 'r'
           and not exists (
               select 1 from pg_trigger t
               where t.tgrelid = c.oid and not t.tgisinternal
                 and t.tgname = '00_touch_row_' || c.relname
           );
        raise exception 'these public tables carry no standard row trigger and cannot be synchronized: %', missing
            using errcode = 'feature_not_supported',
                  hint = 'attach app.attach_standard_triggers() in the migration that creates the table';
    end if;

    if n_tables <> 90 then
        raise exception 'expected 90 synchronization-managed tables, found %', n_tables
            using errcode = 'feature_not_supported',
                  hint = 'WP-8 was designed against the 90 tables in docs/schema.md; a changed inventory needs a reviewed migration, not a silent one';
    end if;
end $$;

-- ===========================================================================
-- 1 · change_xid
-- ===========================================================================
-- Nullable, no default, no backfill. Existing rows stay NULL on purpose: NULL
-- means "written before the feed existed", and the WP-8 bootstrap is what
-- establishes a client's initial mirror and its first cursor. Giving those rows
-- a value would be a lie about when they changed, and backfilling them with
-- today's transaction id would make every existing row appear in the first
-- incremental pull of every client.
--
-- A nullable column with no default is a catalogue change only -- PostgreSQL 11
-- and later do not rewrite the heap for it -- so this is cheap on a large table
-- even though it takes ACCESS EXCLUSIVE for the duration.
do $$
declare t record;
begin
    for t in
        select c.relname
          from pg_class c join pg_namespace n on n.oid = c.relnamespace
         where n.nspname = 'public' and c.relkind = 'r'
         order by c.relname
    loop
        execute format(
            'alter table public.%I add column if not exists change_xid xid8', t.relname);
        execute format(
            'comment on column public.%I.change_xid is %L', t.relname,
            'The transaction that last wrote this row, stamped by app.touch_row(). '
            'NULL means the row predates WP-8 and belongs to bootstrap rather than to an incremental pull.');
    end loop;
end $$;

-- ===========================================================================
-- 2 · The partial index behind the pull query
-- ===========================================================================
-- Partial on `change_xid is not null` because the NULL rows are exactly the
-- ones a pull never returns: indexing them would cost write throughput on every
-- table to store entries no query will ever read.
--
-- Ordinary CREATE INDEX, not CONCURRENTLY. The runner puts each migration in a
-- single transaction (ADR-0002) and CONCURRENTLY cannot run in one; splitting
-- 0018 into a no-transaction migration to allow it would trade an atomic
-- schema change for a partially-applied one. The lock is not the deciding
-- factor either way -- step 1 above already holds ACCESS EXCLUSIVE on all 90
-- tables in this same transaction, so the index build adds no new lock class.
do $$
declare t record;
begin
    for t in
        select c.relname
          from pg_class c join pg_namespace n on n.oid = c.relnamespace
         where n.nspname = 'public' and c.relkind = 'r'
         order by c.relname
    loop
        execute format(
            'create index if not exists %I on public.%I (change_xid) where change_xid is not null',
            t.relname || '_change_xid_idx', t.relname);
    end loop;
end $$;

-- ===========================================================================
-- 3 · Stamping, through the existing standard trigger
-- ===========================================================================
-- The whole body of app.touch_row() from 0002 is reproduced unchanged and one
-- assignment is added to each branch. There is no second trigger system: the
-- stamp rides the mechanism that is already attached to all 90 tables, which is
-- what keeps "has a row spine" and "is synchronizable" the same statement.
--
-- The assignment is unconditional, so a client-supplied change_xid is
-- overwritten rather than trusted. No client value establishes authority.
--
-- pg_current_xact_id() assigns a real transaction id if this transaction does
-- not have one yet. That is correct and not a side effect to avoid: the trigger
-- only ever runs on a write, the write is about to take an xid anyway, and it
-- takes the same one the tuple will be stamped with.
create or replace function app.touch_row()
returns trigger
language plpgsql
as $$
begin
    if TG_OP = 'INSERT' then
        new.created_at := coalesce(new.created_at, now());
        new.created_by := coalesce(new.created_by, app.current_user_id());
        new.updated_at := new.created_at;
        new.updated_by := new.created_by;
        new.row_version := 1;
        new.change_xid := pg_current_xact_id();
        return new;
    end if;

    -- created_* are immutable once written.
    new.created_at := old.created_at;
    new.created_by := old.created_by;
    new.updated_at := now();
    new.updated_by := coalesce(app.current_user_id(), old.updated_by);
    new.row_version := old.row_version + 1;
    new.change_xid := pg_current_xact_id();
    return new;
end $$;

comment on function app.touch_row() is
    'Maintains created/updated columns, row_version and the WP-8 change_xid cursor. Attached to every application table.';

-- ===========================================================================
-- 4 · `authenticated` cannot hard-delete
-- ===========================================================================
-- A revoke, not a policy change. The existing tenant policies are untouched:
-- they decide which rows exist for a caller, and that question is unrelated to
-- whether hard deletion is permitted at all.
--
-- This is a pure withdrawal and grants nothing, so the tables that already
-- withheld DELETE from `authenticated` -- audit_event (0009, 0011),
-- journal_entry and journal_line (0012), user_credential (0016) -- are
-- unaffected and keep their existing posture exactly.
revoke delete on all tables in schema public from authenticated;

-- ===========================================================================
-- 5 · The C1 guard
-- ===========================================================================
-- One shared function and one shared attach helper, mirroring
-- app.attach_standard_triggers() and app.attach_audit(). Ninety near-identical
-- hand-written triggers is ninety chances to write one of them differently.
create or replace function app.assert_sync_visible_delete()
returns trigger
language plpgsql
as $$
begin
    raise exception
        'hard delete of %.% is not permitted: a synchronization-managed row must be removed by soft delete (WP-8 C1)',
        TG_TABLE_SCHEMA, TG_TABLE_NAME
        using errcode = 'insufficient_privilege',
              hint = 'set deleted_at instead; the update stamps change_xid and the removal reaches every client';
end $$;

comment on function app.assert_sync_visible_delete() is
    'Refuses hard deletion of a synchronization-managed row. A DELETE removes a row from a state-based feed with no trace, so the client would keep its copy forever; soft deletion travels as an ordinary change (WP-8 C1).';

create or replace function app.attach_delete_guard(target_table text)
returns void
language plpgsql
as $$
begin
    execute format('drop trigger if exists %I on public.%I',
        'zzzz_no_hard_delete_' || target_table, target_table);
    execute format(
        'create trigger %I before delete on public.%I
             for each row execute function app.assert_sync_visible_delete()',
        'zzzz_no_hard_delete_' || target_table, target_table);
end $$;

comment on function app.attach_delete_guard(text) is
    'Wires the C1 hard-delete guard onto an application table. Named zzzz_ so that it fires last among BEFORE triggers and leaves the existing audit and ledger immutability messages in place.';

-- PostgreSQL grants EXECUTE on every new function to PUBLIC, which reaches
-- `anon` -- the default db/tests/0014_security_audit.sql exists to catch, and
-- the reason every migration in this repository revokes explicitly. Neither
-- function needs a grant to do its job: a trigger function is invoked by the
-- system regardless of EXECUTE privilege (0011), and the attach helper is
-- migration machinery that only the owner ever calls.
revoke all on function app.assert_sync_visible_delete() from public, anon, authenticated;
revoke all on function app.attach_delete_guard(text) from public, anon, authenticated;

-- zzzz_ is deliberate. BEFORE row triggers fire in name order, so the existing
-- guards keep their precedence and their messages:
--   b_*_authz                    authorization refusals on identity tables
--   zz_audit_event_immutable     audit_event stays append-only, in its own words
--   zzz_journal_*_immutable      the ledger stays immutable, in its own words
-- This guard is the backstop underneath all of them, and it is still fail
-- closed: an earlier trigger either raises, or suppresses the row by returning
-- NULL, or falls through to here. None of those three outcomes deletes a row.
do $$
declare t record;
begin
    for t in
        select c.relname
          from pg_class c join pg_namespace n on n.oid = c.relnamespace
         where n.nspname = 'public' and c.relkind = 'r'
         order by c.relname
    loop
        perform app.attach_delete_guard(t.relname);
    end loop;
end $$;

-- ===========================================================================
-- 6 · service_role containment
-- ===========================================================================
-- service_role is trusted to act for the application; it is not trusted to
-- break the invariant the application depends on. It is `nologin noinherit
-- bypassrls` and holds no role membership, so it is neither an owner nor a
-- superuser and cannot re-grant to itself.
--
-- DELETE is belt and braces -- the trigger already refuses it -- and TRUNCATE
-- is the part that is load-bearing, because TRUNCATE fires no row-level
-- trigger. A statement-level BEFORE TRUNCATE trigger would also block the
-- owner, and owner maintenance is explicitly outside this invariant, so the
-- containment is a privilege withdrawal instead.
revoke delete, truncate on all tables in schema public from service_role;

-- ===========================================================================
-- Verification — the migration proves its own result, or does not apply
-- ===========================================================================
do $$
declare
    n_tables    integer;
    n_column    integer;
    n_typed     integer;
    n_default   integer;
    n_notnull   integer;
    n_index     integer;
    n_guard     integer;
    n_backfill  integer;
    n_auth_del  integer;
    n_svc_del   integer;
    n_svc_trunc integer;
    tbl         record;
    hits        integer;
begin
    select count(*) into n_tables
      from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind = 'r';

    select count(*), count(*) filter (where a.atttypid = 'pg_catalog.xid8'::regtype),
           count(*) filter (where a.atthasdef), count(*) filter (where a.attnotnull)
      into n_column, n_typed, n_default, n_notnull
      from pg_attribute a
      join pg_class c on c.oid = a.attrelid
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind = 'r'
       and a.attname = 'change_xid' and a.attnum > 0 and not a.attisdropped;

    select count(*) into n_index
      from pg_class i join pg_namespace n on n.oid = i.relnamespace
     where n.nspname = 'public' and i.relkind = 'i'
       and i.relname like '%\_change\_xid\_idx';

    select count(*) into n_guard
      from pg_trigger t join pg_class c on c.oid = t.tgrelid
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and not t.tgisinternal
       and t.tgname = 'zzzz_no_hard_delete_' || c.relname;

    if n_column <> n_tables then
        raise exception 'change_xid reached % of % tables', n_column, n_tables;
    end if;
    if n_typed <> n_tables then
        raise exception 'change_xid is not xid8 on % table(s) -- an existing column of another type was left in place',
            n_tables - n_typed;
    end if;
    if n_default <> 0 then
        raise exception 'change_xid carries a default on % table(s); it must be written by the trigger only', n_default;
    end if;
    if n_notnull <> 0 then
        raise exception 'change_xid is NOT NULL on % table(s); existing rows must be allowed to stay NULL', n_notnull;
    end if;
    if n_index <> n_tables then
        raise exception 'change_xid index reached % of % tables', n_index, n_tables;
    end if;
    if n_guard <> n_tables then
        raise exception 'C1 delete guard reached % of % tables', n_guard, n_tables;
    end if;

    -- No row was backfilled. Counted rather than assumed, because a stray
    -- UPDATE anywhere in this migration would be invisible otherwise.
    n_backfill := 0;
    for tbl in
        select c.relname
          from pg_class c join pg_namespace n on n.oid = c.relnamespace
         where n.nspname = 'public' and c.relkind = 'r'
    loop
        execute format('select count(*) from public.%I where change_xid is not null', tbl.relname) into hits;
        n_backfill := n_backfill + hits;
    end loop;
    if n_backfill <> 0 then
        raise exception '% existing row(s) received a change_xid; 0018 must not backfill', n_backfill;
    end if;

    select count(*) into n_auth_del from information_schema.role_table_grants
     where table_schema = 'public' and grantee = 'authenticated' and privilege_type = 'DELETE';
    select count(*) into n_svc_del from information_schema.role_table_grants
     where table_schema = 'public' and grantee = 'service_role' and privilege_type = 'DELETE';
    select count(*) into n_svc_trunc from information_schema.role_table_grants
     where table_schema = 'public' and grantee = 'service_role' and privilege_type = 'TRUNCATE';

    if n_auth_del <> 0 then
        raise exception 'authenticated retains DELETE on % table(s)', n_auth_del;
    end if;
    if n_svc_del <> 0 or n_svc_trunc <> 0 then
        raise exception 'service_role retains DELETE on % and TRUNCATE on % table(s)', n_svc_del, n_svc_trunc;
    end if;

    -- The functions 0018 introduces must not be reachable by an application
    -- role, for the same reason every other app function is not.
    if exists (
        select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'app'
           and p.proname in ('assert_sync_visible_delete', 'attach_delete_guard')
           and (has_function_privilege('public', p.oid, 'EXECUTE')
             or has_function_privilege('anon', p.oid, 'EXECUTE')
             or has_function_privilege('authenticated', p.oid, 'EXECUTE'))
    ) then
        raise exception 'a function introduced by 0018 is still executable by an application role'
            using errcode = 'insufficient_privilege';
    end if;

    raise notice '0018: change_xid, index and C1 guard on % tables; no row backfilled', n_tables;
end $$;

comment on function app.attach_standard_triggers(text) is
    'Wires the standard row-maintenance trigger onto an application table. Since 0018 that trigger also stamps the WP-8 change_xid cursor.';
