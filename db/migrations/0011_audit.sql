-- 0011 · Audit framework (WP-4)
--
-- BR-13: money and permission changes write an audit row carrying who, what,
-- when, before, after and a reason where one is required.
--
-- The capture is done by database triggers rather than by application code, and
-- that is the whole point. Application-side auditing is written once per code
-- path and forgotten on the second one; six weeks later the log is missing the
-- exact event somebody needs. A trigger cannot be forgotten, and it records a
-- change made from a SQL console just as faithfully as one made from the app.
--
-- Four pieces:
--   * app.audit_row()          the generic capture trigger
--   * audit_reason_requirement which actions demand a reason (AP-1: data)
--   * app.audit_immutable()    makes an audit row unalterable by anyone
--   * app.set_context()        how an actor, device and reason reach the trigger

-- ===========================================================================
-- Which actions demand a reason — configuration, not a constant (AP-1)
-- ===========================================================================
create table audit_reason_requirement (
    id                uuid primary key default gen_random_uuid(),
    business_id       uuid not null references business(id),

    entity_type       text not null,
    action            text not null
        constraint audit_reason_requirement_action_valid check (action in ('insert','update','delete','any')),
    -- Optional narrowing: demand a reason only when a particular column changes,
    -- so a price override needs one but correcting a spelling does not.
    column_name       text,
    requires_reason   boolean not null default true,
    note              text,

    created_at        timestamptz not null default now(),
    created_by        uuid,
    updated_at        timestamptz not null default now(),
    updated_by        uuid,
    deleted_at        timestamptz,
    row_version       integer not null default 1
);

comment on table audit_reason_requirement is
    'Which changes cannot be made without saying why (BR-13). Owner-configurable: the list of actions that demand a reason is a business decision, not a constant in code.';

create unique index audit_reason_requirement_unique
    on audit_reason_requirement (business_id, entity_type, action, coalesce(column_name, ''))
    where deleted_at is null;

select app.attach_standard_triggers('audit_reason_requirement');

-- Migration 0010 made new tables unreachable by default. Every migration that
-- creates one must therefore grant and protect it explicitly - which is the
-- fail-loudly behaviour that decision was chosen for.
grant select, insert, update, delete on audit_reason_requirement to authenticated;
grant all on audit_reason_requirement to service_role;
alter table audit_reason_requirement enable row level security;
create policy audit_reason_requirement_tenant on audit_reason_requirement
    for all to authenticated
    using (business_id = app.current_business_id())
    with check (business_id = app.current_business_id());

-- ===========================================================================
-- Session context
-- ===========================================================================
-- Under PostgREST the actor arrives in the JWT. Server-side jobs and the
-- console have no JWT, so they set these session variables instead. Both paths
-- end up in the same audit columns, which is what makes an out-of-band change
-- as visible as an in-app one.
create or replace function app.set_context(
    actor_id    uuid    default null,
    device_id   uuid    default null,
    reason_code text    default null,
    reason_text text    default null
) returns void
language plpgsql
as $$
begin
    perform set_config('app.actor_id',    coalesce(actor_id::text, ''),  true);
    perform set_config('app.device_id',   coalesce(device_id::text, ''), true);
    perform set_config('app.reason_code', coalesce(reason_code, ''),     true);
    perform set_config('app.reason_text', coalesce(reason_text, ''),     true);
end $$;

comment on function app.set_context(uuid, uuid, text, text) is
    'Supplies actor, device and reason for the statements that follow, for callers with no JWT. Transaction-scoped: it does not leak into the next request.';

-- Attribution must never be able to block a sale.
--
-- audit_event.device_id is a foreign key, which is right: an audit row pointing
-- at a device that does not exist says nothing. But a client that sends a stale
-- or malformed device id would then fail the audit insert and, because the
-- trigger runs inside the caller's transaction, fail the order behind it.
--
-- Losing an attribution field is a data-quality problem. Refusing to take a
-- customer's order at the counter is a business failure. So the device is
-- resolved defensively: attributed when it is known, null when it is not, and
-- never a reason for the write to fail. WP-7 registers devices at sign-in, and
-- a test asserts a registered device IS attributed - so this tolerance cannot
-- quietly become the normal case.
create or replace function app.resolved_device_id()
returns uuid
language sql
stable
security definer
set search_path = public, pg_temp
as $$
    select d.id from device d
    where d.id = app.current_device_id() and d.deleted_at is null;
$$;

create or replace function app.current_reason_text()
returns text language sql stable as $$
    select nullif(current_setting('app.reason_text', true), '');
$$;

-- Where the change came from. A change made outside the application is recorded
-- as such rather than being invisible or, worse, attributed to somebody.
create or replace function app.current_source()
returns text language plpgsql stable as $$
begin
    if app.jwt() ? 'sub' then
        return 'app';
    elsif nullif(current_setting('app.actor_id', true), '') is not null then
        return 'system';
    else
        return 'console';
    end if;
end $$;

grant execute on function app.set_context(uuid, uuid, text, text) to authenticated, service_role;
grant execute on function app.resolved_device_id() to authenticated, service_role;
grant execute on function app.current_reason_text() to authenticated, service_role;
grant execute on function app.current_source() to authenticated, service_role;

-- ===========================================================================
-- The capture trigger
-- ===========================================================================
-- Columns that change on every write and say nothing about intent. They are
-- still stored in before/after, but they do not count as a change: without this
-- every touch would produce an audit row and the log would be noise.
create or replace function app.audit_ignored_columns()
returns text[] language sql immutable as $$
    select array['updated_at','updated_by','row_version']::text[];
$$;

create or replace function app.audit_row()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    before_data   jsonb;
    after_data    jsonb;
    changed       text[];
    action_name   text;
    v_business_id uuid;
    v_branch_id   uuid;
    v_reason_code text;
    needs_reason  boolean;
begin
    if TG_OP = 'INSERT' then
        action_name := 'insert';
        before_data := null;
        after_data  := to_jsonb(new);
    elsif TG_OP = 'UPDATE' then
        action_name := 'update';
        before_data := to_jsonb(old);
        after_data  := to_jsonb(new);
        select coalesce(array_agg(key order by key), array[]::text[])
          into changed
          from jsonb_each(after_data) e(key, value)
         where not (key = any(app.audit_ignored_columns()))
           and before_data -> key is distinct from value;
        -- A statement that changed nothing meaningful is not an event.
        if changed = array[]::text[] then
            return null;
        end if;
    else
        action_name := 'delete';
        before_data := to_jsonb(old);
        after_data  := null;
    end if;

    v_business_id := coalesce((after_data ->> 'business_id')::uuid,
                              (before_data ->> 'business_id')::uuid);
    v_branch_id   := coalesce((after_data ->> 'branch_id')::uuid,
                              (before_data ->> 'branch_id')::uuid);
    v_reason_code := app.current_reason();

    -- Reason enforcement applies to acts by a person. A migration or a restore
    -- has no actor to ask, and blocking those would make the database
    -- unmaintainable; those changes are still recorded, with source 'console'
    -- or 'system', which is what makes them reviewable after the fact.
    if app.current_user_id() is not null and v_reason_code is null then
        select exists (
            select 1 from audit_reason_requirement r
            where r.business_id = v_business_id
              and r.entity_type = TG_TABLE_NAME
              and r.requires_reason
              and r.deleted_at is null
              and (r.action = action_name or r.action = 'any')
              and (r.column_name is null or r.column_name = any(coalesce(changed, array[]::text[])))
        ) into needs_reason;

        if needs_reason then
            raise exception
                'a reason is required to % %', action_name, TG_TABLE_NAME
                using errcode = 'check_violation',
                      hint = 'call app.set_context(..., reason_code => ...) before the statement';
        end if;
    end if;

    insert into audit_event (
        business_id, branch_id, entity_type, entity_id, action,
        before_data, after_data, changed_fields,
        reason_code, reason_text,
        actor_user_id, device_id, source, occurred_at, recorded_at
    ) values (
        v_business_id, v_branch_id, TG_TABLE_NAME,
        coalesce((after_data ->> 'id')::uuid, (before_data ->> 'id')::uuid),
        action_name, before_data, after_data, changed,
        v_reason_code, app.current_reason_text(),
        app.current_user_id(), app.resolved_device_id(), app.current_source(),
        now(), now()
    );

    return null;
end $$;

comment on function app.audit_row() is
    'Generic audit capture. SECURITY DEFINER so it can write audit_event even for a caller who may only insert through a policy, and so a caller cannot suppress it.';

create or replace function app.attach_audit(target_table text)
returns void language plpgsql as $$
begin
    execute format('drop trigger if exists %I on public.%I', 'zz_audit_' || target_table, target_table);
    execute format(
        'create trigger %I after insert or update or delete on public.%I
             for each row execute function app.audit_row()',
        'zz_audit_' || target_table, target_table);
end $$;

comment on function app.attach_audit(text) is
    'Attaches audit capture to a table. Named zz_ so it fires after the row-maintenance trigger, which is 00_.';

-- ===========================================================================
-- The audit trail cannot be rewritten, by anyone
-- ===========================================================================
-- Policies and grants already stop an application caller. This stops the table
-- owner too, so the guarantee does not depend on nobody ever connecting as
-- postgres. Removing it means dropping a trigger, which is itself a schema
-- change and therefore visible.
create or replace function app.audit_immutable()
returns trigger language plpgsql as $$
begin
    raise exception 'audit_event is append-only: rows cannot be % (BR-13)',
        case TG_OP when 'UPDATE' then 'modified' else 'deleted' end
        using errcode = 'insufficient_privilege';
end $$;

drop trigger if exists zz_audit_event_immutable on audit_event;
create trigger zz_audit_event_immutable
    before update or delete on audit_event
    for each row execute function app.audit_immutable();

-- The row-maintenance trigger would try to update audit rows on write; it is
-- harmless on insert but the immutability trigger is clearer without it.
revoke update, delete on audit_event from authenticated;

-- ===========================================================================
-- Attach audit capture to the tables BR-13 covers
-- ===========================================================================
-- The list is deliberately explicit rather than "every table": auditing
-- everything doubles write volume for tables where nothing of consequence
-- happens. A coverage test asserts this list matches the events BR-13 names, so
-- it cannot quietly shrink.
do $$
declare t text;
begin
    foreach t in array array[
        -- money
        'payment','payment_allocation','invoice','invoice_line','credit_note',
        'cash_session','journal_entry','journal_line','expense','purchase_bill',
        -- orders and the promises made in them
        'sales_order','order_item','garment','delivery_note','delivery_line',
        'date_override','alteration',
        -- wages
        'wage_entry','wage_payout','wage_rate','wage_scheme','staff_advance',
        -- stock and custody
        'stock_movement','stock_transfer','customer_material','customer_material_movement',
        -- identity, permissions and configuration
        'app_user','role','permission','role_permission','user_branch_role',
        'config_setting','config_version','config_branch_override',
        'tax_code','tax_rate','tax_rate_component','tax_profile',
        'price_list','price_list_item','validation_signoff',
        -- customer records and measurements
        'customer','customer_merge','measurement_revision','measurement_snapshot',
        'number_void'
    ] loop
        perform app.attach_audit(t);
    end loop;
end $$;
