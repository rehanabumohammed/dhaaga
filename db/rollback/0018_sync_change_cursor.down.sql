-- Rollback of 0018 · Synchronization change cursor and the C1 deletion invariant
--
-- Restores the pre-0018 state exactly, including the privilege exceptions that
-- existed before it. There is deliberately no `grant delete on all tables`
-- shortcut here: four tables withheld DELETE from `authenticated` before 0018
-- ran, and a blanket grant would hand it back to them and quietly undo three
-- earlier security migrations.
--
-- The pre-0018 exceptions, each with the line that created it:
--   audit_event      0009_rls.sql:173 and 0011_audit.sql:269  (append-only, BR-13)
--   journal_entry    0012_ledger.sql:122                      (posted entries are immutable, BR-04)
--   journal_line     0012_ledger.sql:123                      (posted entries are immutable, BR-04)
--   user_credential  0016_identity.sql:672                    (revoked from every application role)
--
-- Everything this script touches is scoped to the tables that actually carry
-- change_xid, so it reverses what 0018 did and nothing else.

-- ===========================================================================
-- 1 · Remove the C1 guard
-- ===========================================================================
do $$
declare t record;
begin
    for t in
        select c.relname
          from pg_class c
          join pg_namespace n on n.oid = c.relnamespace
          join pg_attribute a on a.attrelid = c.oid
         where n.nspname = 'public' and c.relkind = 'r'
           and a.attname = 'change_xid' and a.attnum > 0 and not a.attisdropped
         order by c.relname
    loop
        execute format('drop trigger if exists %I on public.%I',
            'zzzz_no_hard_delete_' || t.relname, t.relname);
    end loop;
end $$;

drop function if exists app.attach_delete_guard(text);
drop function if exists app.assert_sync_visible_delete();

-- ===========================================================================
-- 2 · Restore privileges, table by table, exceptions preserved
-- ===========================================================================
do $$
declare
    t          record;
    withheld   text[] := array['audit_event', 'journal_entry', 'journal_line', 'user_credential'];
    n_auth     integer;
    n_svc_del  integer;
    n_svc_trnc integer;
begin
    for t in
        select c.relname
          from pg_class c
          join pg_namespace n on n.oid = c.relnamespace
          join pg_attribute a on a.attrelid = c.oid
         where n.nspname = 'public' and c.relkind = 'r'
           and a.attname = 'change_xid' and a.attnum > 0 and not a.attisdropped
         order by c.relname
    loop
        -- service_role held `all` on every table before 0018 (0009_rls.sql:109),
        -- with no exception -- audit_event and the ledger tables included, since
        -- their protection is a trigger rather than a privilege.
        execute format('grant delete, truncate on public.%I to service_role', t.relname);

        if not (t.relname = any (withheld)) then
            execute format('grant delete on public.%I to authenticated', t.relname);
        end if;
    end loop;

    select count(*) into n_auth from information_schema.role_table_grants
     where table_schema = 'public' and grantee = 'authenticated' and privilege_type = 'DELETE';
    select count(*) into n_svc_del from information_schema.role_table_grants
     where table_schema = 'public' and grantee = 'service_role' and privilege_type = 'DELETE';
    select count(*) into n_svc_trnc from information_schema.role_table_grants
     where table_schema = 'public' and grantee = 'service_role' and privilege_type = 'TRUNCATE';

    -- 90 tables, of which four withheld DELETE from authenticated: 86.
    if n_auth <> 86 or n_svc_del <> 90 or n_svc_trnc <> 90 then
        raise exception
            'rollback did not restore the pre-0018 privilege state: authenticated DELETE on % (expected 86), service_role DELETE on % and TRUNCATE on % (expected 90 each)',
            n_auth, n_svc_del, n_svc_trnc
            using errcode = 'insufficient_privilege';
    end if;

    -- And the four exceptions are still exceptions.
    if exists (
        select 1 from information_schema.role_table_grants
         where table_schema = 'public' and grantee = 'authenticated'
           and privilege_type = 'DELETE'
           and table_name = any (withheld)
    ) then
        raise exception 'rollback handed DELETE back to authenticated on a table that never had it'
            using errcode = 'insufficient_privilege';
    end if;
end $$;

-- ===========================================================================
-- 3 · Restore app.touch_row() to its 0002 definition
-- ===========================================================================
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
        return new;
    end if;

    -- created_* are immutable once written.
    new.created_at := old.created_at;
    new.created_by := old.created_by;
    new.updated_at := now();
    new.updated_by := coalesce(app.current_user_id(), old.updated_by);
    new.row_version := old.row_version + 1;
    return new;
end $$;

comment on function app.touch_row() is
    'Maintains created/updated columns and row_version. Attached to every application table.';

comment on function app.attach_standard_triggers(text) is
    'Wires the standard row-maintenance trigger onto an application table.';

-- ===========================================================================
-- 4 · Drop the indexes and the column
-- ===========================================================================
do $$
declare t record;
begin
    for t in
        select c.relname
          from pg_class c
          join pg_namespace n on n.oid = c.relnamespace
          join pg_attribute a on a.attrelid = c.oid
         where n.nspname = 'public' and c.relkind = 'r'
           and a.attname = 'change_xid' and a.attnum > 0 and not a.attisdropped
         order by c.relname
    loop
        execute format('drop index if exists public.%I', t.relname || '_change_xid_idx');
        execute format('alter table public.%I drop column if exists change_xid', t.relname);
    end loop;
end $$;

do $$
declare leftover integer;
begin
    select count(*) into leftover
      from pg_attribute a
      join pg_class c on c.oid = a.attrelid
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind = 'r'
       and a.attname = 'change_xid' and a.attnum > 0 and not a.attisdropped;
    if leftover <> 0 then
        raise exception 'change_xid still present on % table(s) after rollback', leftover;
    end if;
end $$;
