-- 0013 · Closing a tenant-isolation bypass, and hardening SECURITY DEFINER
--
-- Found by the WP-5 audit. Three defects, one of them critical. None of them
-- required a design change: the architecture (tenant derived from the caller's
-- user row, isolation enforced by policy) was right. The implementation had
-- holes that let a caller step around it.
--
-- ---------------------------------------------------------------------------
-- DEFECT 1 (critical) · identity could be reassigned by the caller
-- ---------------------------------------------------------------------------
-- app.current_user_id() consulted the `app.actor_id` session variable BEFORE
-- the JWT, so that server-side jobs could act as a user. app.set_context(),
-- which sets that variable, was granted to `authenticated` so the client could
-- supply a device and a reason.
--
-- Each decision was defensible alone. Together they meant an authenticated user
-- of business A could call set_context naming any user of business B and become
-- that user for every policy in the database - reading, writing and being
-- audited as them. Reproduced end to end before this fix.
--
-- The fix is an ordering change: a verified token always wins. The session
-- override is consulted only when there is no token at all, which is the
-- server-side and console case it was written for. A REST caller always carries
-- a token, so the override is unreachable from there.
--
-- ---------------------------------------------------------------------------
-- DEFECT 2 (high) · SECURITY DEFINER functions did not re-assert the boundary
-- ---------------------------------------------------------------------------
-- app.post_entry() and app.reverse_journal_entry() run as their owner, which
-- is the point - they must see every line of an entry to balance it. But that
-- also means row-level security does not apply inside them, and neither
-- re-checked the tenant. An authenticated user could post ledger entries into
-- a branch they hold no grant for, using nothing but a branch id that is
-- visible to them anyway. Reproduced before this fix.
--
-- A SECURITY DEFINER function must re-assert every boundary it bypasses. That
-- is now a named, reusable check rather than a thing each function remembers.
--
-- ---------------------------------------------------------------------------
-- DEFECT 3 (defence in depth) · EXECUTE granted to PUBLIC by default
-- ---------------------------------------------------------------------------
-- PostgreSQL grants EXECUTE on new functions to PUBLIC. Not currently reachable
-- by `anon`, which holds no USAGE on the app schema - but a single future grant
-- would have made every SECURITY DEFINER function anonymously callable.

-- ===========================================================================
-- Defect 1 · a verified token always wins
-- ===========================================================================
create or replace function app.current_user_id()
returns uuid
language plpgsql
stable
as $$
declare
    claim    text;
    override text;
begin
    -- The JWT is verified by the auth layer before it reaches us. If one is
    -- present it IS the identity, and nothing a caller can set may displace it.
    claim := app.jwt() ->> 'sub';
    if claim is not null and claim <> '' then
        return claim::uuid;
    end if;

    -- No token: a migration, a background job or a console session. Only here
    -- is the session override consulted.
    override := nullif(current_setting('app.actor_id', true), '');
    if override is not null then
        return override::uuid;
    end if;

    return null;
exception when invalid_text_representation then
    return null;
end $$;

comment on function app.current_user_id() is
    'The acting user. A verified JWT subject always takes precedence; the app.actor_id override applies only when there is no token, which is the server-side case it exists for. The ordering is load-bearing: reversing it lets a caller reassign their own identity.';

-- ===========================================================================
-- Defect 1 · the client can set a device and a reason, never an identity
-- ===========================================================================
-- app.set_context() keeps its full signature for server-side callers and is no
-- longer reachable by application users. Clients get a narrower function that
-- cannot name an actor at all - the two capabilities are separated rather than
-- protected by a promise not to misuse one of them.
create or replace function app.set_request_context(
    device_id   uuid default null,
    reason_code text default null,
    reason_text text default null
) returns void
language plpgsql
as $$
begin
    perform set_config('app.device_id',   coalesce(device_id::text, ''), true);
    perform set_config('app.reason_code', coalesce(reason_code, ''),     true);
    perform set_config('app.reason_text', coalesce(reason_text, ''),     true);
end $$;

comment on function app.set_request_context(uuid, text, text) is
    'Supplies the device and the reason for the statements that follow. Deliberately cannot set an actor: identity comes from the verified token and from nowhere else.';

-- ===========================================================================
-- Defect 2 · a named boundary check for SECURITY DEFINER functions
-- ===========================================================================
create or replace function app.assert_tenant_write(
    p_business_id uuid,
    p_branch_id   uuid default null
) returns void
language plpgsql
stable
as $$
declare v_business uuid;
begin
    -- No user context means a migration, a restore or a background job, which
    -- legitimately writes across the whole database. Those paths are recorded
    -- by the audit trail with a source of 'system' or 'console'.
    if app.current_user_id() is null then
        return;
    end if;

    v_business := app.current_business_id();

    if v_business is null or p_business_id is distinct from v_business then
        raise exception 'refused: this caller may not write into business %', p_business_id
            using errcode = 'insufficient_privilege',
                  hint = 'a SECURITY DEFINER function must re-assert the boundary it bypasses';
    end if;

    if p_branch_id is not null and not app.has_branch(p_branch_id) then
        raise exception 'refused: this caller holds no grant for branch %', p_branch_id
            using errcode = 'insufficient_privilege';
    end if;
end $$;

comment on function app.assert_tenant_write(uuid, uuid) is
    'Re-asserts the tenant and branch boundary inside a SECURITY DEFINER function, where row-level security does not apply. Every such function that accepts a caller-supplied business or branch must call this.';

-- ===========================================================================
-- Defect 2 · apply the check inside the ledger functions
-- ===========================================================================
create or replace function app.post_entry(
    p_business_id     uuid,
    p_branch_id       uuid,
    p_source_doc_type text,
    p_source_doc_id   uuid,
    p_memo            text,
    p_lines           jsonb,
    p_entry_date      date default current_date
) returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_entry_id     uuid := gen_random_uuid();
    v_line         jsonb;
    v_no           integer := 0;
    v_bad_accounts integer;
begin
    -- Row-level security does not apply inside this function. Re-assert it.
    perform app.assert_tenant_write(p_business_id, p_branch_id);

    set constraints all deferred;

    if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) < 2 then
        raise exception 'an entry needs at least two lines'
            using errcode = 'check_violation';
    end if;

    -- An account belonging to another business would post real money into
    -- someone else's books through a legitimately-scoped entry.
    select count(*) into v_bad_accounts
      from jsonb_array_elements(p_lines) l
      left join account a on a.id = (l ->> 'account_id')::uuid
     where a.id is null or a.business_id <> p_business_id;

    if v_bad_accounts > 0 then
        raise exception 'refused: % line(s) reference an account outside business %',
            v_bad_accounts, p_business_id
            using errcode = 'insufficient_privilege';
    end if;

    insert into journal_entry (id, business_id, branch_id, entry_date,
                               source_doc_type, source_doc_id, memo)
    values (v_entry_id, p_business_id, p_branch_id, p_entry_date,
            p_source_doc_type, p_source_doc_id, p_memo);

    for v_line in select * from jsonb_array_elements(p_lines) loop
        v_no := v_no + 1;
        insert into journal_line (
            business_id, branch_id, entry_id, account_id, line_no,
            debit, credit, customer_id, supplier_id, garment_id, staff_id,
            stock_item_id, memo)
        values (
            p_business_id, p_branch_id, v_entry_id,
            (v_line ->> 'account_id')::uuid, v_no,
            coalesce((v_line ->> 'debit')::numeric, 0),
            coalesce((v_line ->> 'credit')::numeric, 0),
            (v_line ->> 'customer_id')::uuid,
            (v_line ->> 'supplier_id')::uuid,
            (v_line ->> 'garment_id')::uuid,
            (v_line ->> 'staff_id')::uuid,
            (v_line ->> 'stock_item_id')::uuid,
            v_line ->> 'memo');
    end loop;

    return v_entry_id;
end $$;

create or replace function app.reverse_journal_entry(
    p_entry_id     uuid,
    p_reason_code  text,
    p_reason_text  text default null,
    p_entry_date   date default current_date
) returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_original journal_entry;
    v_new_id   uuid := gen_random_uuid();
begin
    select * into v_original from journal_entry where id = p_entry_id;
    if not found then
        raise exception 'journal entry % does not exist', p_entry_id
            using errcode = 'no_data_found';
    end if;

    -- Checked against the ORIGINAL entry's business, not against anything the
    -- caller supplied. Without this, knowing an entry id would be enough to
    -- reverse another business's posting.
    perform app.assert_tenant_write(v_original.business_id, v_original.branch_id);

    set constraints all deferred;

    if v_original.reversal_of_id is not null then
        raise exception 'entry % is itself a reversal and cannot be reversed', p_entry_id
            using errcode = 'check_violation',
                  hint = 'reverse the original entry, or post a fresh correcting entry';
    end if;

    if p_reason_code is null then
        raise exception 'a reversal must record why'
            using errcode = 'check_violation';
    end if;

    insert into journal_entry (id, business_id, branch_id, entry_date,
                               source_doc_type, source_doc_id, memo,
                               reversal_of_id, reversal_reason_code, reversal_reason_text)
    values (v_new_id, v_original.business_id, v_original.branch_id, p_entry_date,
            v_original.source_doc_type, v_original.source_doc_id,
            'Reversal of ' || coalesce(v_original.memo, p_entry_id::text),
            p_entry_id, p_reason_code, p_reason_text);

    insert into journal_line (business_id, branch_id, entry_id, account_id, line_no,
                              debit, credit, customer_id, supplier_id, garment_id,
                              staff_id, stock_item_id, memo)
    select l.business_id, l.branch_id, v_new_id, l.account_id, l.line_no,
           l.credit, l.debit, l.customer_id, l.supplier_id, l.garment_id,
           l.staff_id, l.stock_item_id, 'Reversal: ' || coalesce(l.memo, '')
      from journal_line l
     where l.entry_id = p_entry_id and l.deleted_at is null;

    return v_new_id;
end $$;

-- ===========================================================================
-- Defect 3 · grant EXECUTE deliberately, never by default
-- ===========================================================================
do $$
declare f record;
begin
    for f in
        select p.oid::regprocedure as sig
        from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'app'
    loop
        -- PUBLIC alone is not enough: earlier migrations granted some of these
        -- to `authenticated` explicitly, and an explicit grant survives a
        -- revoke from PUBLIC. Strip every application role, then grant back
        -- deliberately below.
        execute format('revoke all on function %s from public', f.sig);
        execute format('revoke all on function %s from anon', f.sig);
        execute format('revoke all on function %s from authenticated', f.sig);
    end loop;
end $$;

-- Read-only context helpers: the client needs these to render its own state.
grant execute on function app.jwt()                                  to authenticated, service_role;
grant execute on function app.current_user_id()                      to authenticated, service_role;
grant execute on function app.current_business_id()                  to authenticated, service_role;
grant execute on function app.current_branch_ids()                   to authenticated, service_role;
grant execute on function app.has_branch(uuid)                       to authenticated, service_role;
grant execute on function app.set_request_context(uuid, text, text)  to authenticated, service_role;

-- Server-side only. app.set_context can name an actor, so it stays out of
-- reach of application users entirely (defect 1).
grant execute on function app.set_context(uuid, uuid, text, text)    to service_role;

-- The ledger is never written directly by a client. Domain services in P3 are
-- themselves SECURITY DEFINER and call these as their owner, so no application
-- grant is needed - and without one, the boundary check inside them is a second
-- line of defence rather than the only one.
grant execute on function app.post_entry(uuid, uuid, text, uuid, text, jsonb, date) to service_role;
grant execute on function app.reverse_journal_entry(uuid, text, text, date)          to service_role;

-- Trigger functions need no grant at all: the system invokes them regardless of
-- EXECUTE privilege, so leaving them ungranted removes a call path for nothing.
