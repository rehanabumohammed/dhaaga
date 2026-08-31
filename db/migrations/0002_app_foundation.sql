-- 0002 · Application foundation
--
-- The `app` schema holds internal machinery that no client ever selects from
-- directly: session-context helpers, trigger functions and table conventions.
-- Keeping it out of `public` means the PostgREST-exposed surface stays exactly
-- the set of tables and views we intend to expose (ADR-0003).

create schema if not exists app;

comment on schema app is
    'Internal machinery: session context, trigger functions, table conventions. Not exposed to clients.';

-- ---------------------------------------------------------------------------
-- Session context
-- ---------------------------------------------------------------------------
-- Supabase/PostgREST places the verified JWT into request.jwt.claims for the
-- duration of the request. Server-side jobs and the migration runner have no
-- JWT, so they set app.actor_id instead. Every helper below tolerates both and
-- returns null rather than raising when neither is present -- a null actor must
-- fail a policy check, not crash a query.

create or replace function app.jwt()
returns jsonb
language sql stable
as $$
    select coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb;
$$;

comment on function app.jwt() is
    'The verified JWT claims for this request, or an empty object outside a request.';

create or replace function app.current_user_id()
returns uuid
language plpgsql stable
as $$
declare
    claim text;
    override text;
begin
    override := nullif(current_setting('app.actor_id', true), '');
    if override is not null then
        return override::uuid;
    end if;

    claim := app.jwt() ->> 'sub';
    if claim is null or claim = '' then
        return null;
    end if;
    return claim::uuid;
exception when invalid_text_representation then
    return null;
end $$;

comment on function app.current_user_id() is
    'The acting user: the JWT subject, or app.actor_id for server-side work. Null when neither is set.';

create or replace function app.current_device_id()
returns uuid
language plpgsql stable
as $$
declare
    raw text;
begin
    raw := coalesce(
        nullif(current_setting('app.device_id', true), ''),
        app.jwt() ->> 'device_id'
    );
    if raw is null then
        return null;
    end if;
    return raw::uuid;
exception when invalid_text_representation then
    return null;
end $$;

comment on function app.current_device_id() is
    'The device the action came from, for offline attribution. Null when unknown.';

-- The reason supplied for an action that requires one (BR-13). Set per
-- statement by the calling code; consumed by the audit trigger in WP-4.
create or replace function app.current_reason()
returns text
language sql stable
as $$
    select nullif(current_setting('app.reason_code', true), '');
$$;

-- ---------------------------------------------------------------------------
-- Table conventions
-- ---------------------------------------------------------------------------
-- Every table in the application schema carries the same spine:
--   id           uuid primary key, client-generatable (offline-first, §5)
--   business_id  tenant key on every table without exception (AP-7)
--   created_at / updated_at / created_by / updated_by
--   deleted_at   soft delete only (BR-19)
--   row_version  integer, incremented by trigger, for optimistic concurrency (§5.2)
-- Columns are written out explicitly in each CREATE TABLE so a reader sees the
-- whole table; the trigger wiring is applied by the helper below and the
-- presence of the columns is enforced by db/tests/0002_conventions.sql.

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

create or replace function app.attach_standard_triggers(target_table text)
returns void
language plpgsql
as $$
begin
    execute format(
        'drop trigger if exists %I on public.%I',
        '00_touch_row_' || target_table, target_table
    );
    execute format(
        'create trigger %I before insert or update on public.%I
             for each row execute function app.touch_row()',
        '00_touch_row_' || target_table, target_table
    );
end $$;

comment on function app.attach_standard_triggers(text) is
    'Wires the standard row-maintenance trigger onto an application table.';

-- ---------------------------------------------------------------------------
-- Shared domains
-- ---------------------------------------------------------------------------
-- Money is numeric(14,2) everywhere: exact decimal, never floating point, and
-- wide enough for any tailoring transaction. Quantities carry three decimals
-- because fabric is measured in metres to the centimetre.

create domain app.money_amount as numeric(14,2);
create domain app.quantity     as numeric(12,3);
create domain app.rate_percent as numeric(6,3);

comment on domain app.money_amount is 'Exact decimal currency amount. Never float.';
comment on domain app.quantity is 'Physical quantity, three decimals (metres to the centimetre).';
comment on domain app.rate_percent is 'A percentage such as a tax or efficiency rate.';
