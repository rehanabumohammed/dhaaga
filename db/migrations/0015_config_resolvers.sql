-- 0015 · Configuration resolvers (WP-6)
--
-- The registry tables exist (0004) and are seeded. This migration makes them
-- usable and makes AP-1 enforceable rather than aspirational:
--
--   * resolution — what is the value of this rule, for this branch, at this
--     moment or at any moment in the past;
--   * permission — a rule changes only if the caller holds the permission the
--     rule itself names, enforced by trigger so no code path can skip it;
--   * validation — the CA sign-off covers a specific configuration, and stops
--     covering it the moment a covered setting moves (BR-22).
--
-- Resolution order, most specific first:
--   branch override effective at T  ->  business version effective at T
--   ->  current_value  ->  default_value
--
-- BR-15 depends on this: reprinting a two-year-old invoice must use the rate
-- that was in force when it was issued, which is a resolution at a past date.
--
-- ---------------------------------------------------------------------------
-- search_path is pinned on EVERY function here, including the SECURITY INVOKER
-- ones. PostgreSQL searches the session's temporary schema first when pg_temp
-- is not named explicitly in search_path, so an unpinned function that names a
-- relation without a schema can be pointed at a temporary table of the
-- caller's making. For a permission trigger that is not a theoretical concern:
-- a temporary table called config_setting makes the required permission
-- resolve to null and the check pass. Reproduced against an earlier draft of
-- this migration; see ADR-0011.
-- ---------------------------------------------------------------------------

-- ===========================================================================
-- Boundary check for reads
-- ===========================================================================
-- app.assert_tenant_write() (0013) covers SECURITY DEFINER functions that
-- write. A DEFINER function that only reads bypasses row-level security just
-- as completely, and its answer is still information about another tenant, so
-- it needs the same re-assertion under an honest name.
create or replace function app.assert_tenant_read(p_business_id uuid)
returns void
language plpgsql
stable
set search_path = public, pg_temp
as $$
declare v_business uuid;
begin
    -- No user context: a migration, a restore or a background job.
    if app.current_user_id() is null then
        return;
    end if;

    v_business := app.current_business_id();

    if v_business is null or p_business_id is distinct from v_business then
        raise exception 'refused: this caller may not read business %', p_business_id
            using errcode = 'insufficient_privilege',
                  hint = 'a SECURITY DEFINER function must re-assert the boundary it bypasses, whether it reads or writes';
    end if;
end $$;

comment on function app.assert_tenant_read(uuid) is
    'Re-asserts the tenant boundary inside a SECURITY DEFINER function that reads. The read counterpart of app.assert_tenant_write (ADR-0010).';

-- ===========================================================================
-- Permissions
-- ===========================================================================
-- SECURITY DEFINER because it is called from triggers, where the visibility of
-- role_permission may differ from the caller's. It reads only the CALLER's own
-- permissions - it bypasses no boundary and grants nothing - so ADR-0010's rule
-- about re-asserting boundaries has nothing to re-assert here.
create or replace function app.has_permission(p_code text)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
    select exists (
        select 1
        from user_branch_role ubr
        join role_permission rp on rp.role_id = ubr.role_id and rp.deleted_at is null
        join permission p on p.id = rp.permission_id and p.deleted_at is null
        where ubr.user_id = app.current_user_id()
          and ubr.revoked_at is null
          and ubr.deleted_at is null
          and p.code = p_code
    );
$$;

comment on function app.has_permission(text) is
    'Whether the current caller holds a named permission through any of their branch role grants. Reads only the caller''s own permissions.';

-- ===========================================================================
-- Resolution
-- ===========================================================================
-- SECURITY INVOKER deliberately. Under row-level security the caller can
-- already read their own business's configuration and nothing else, so the
-- boundary is enforced by the policies that already exist. Making this DEFINER
-- would open a hole for no benefit - a caller passing another business's id
-- would get that business's settings.
create or replace function app.config_value(
    p_key         text,
    p_business_id uuid        default null,
    p_branch_id   uuid        default null,
    p_at          timestamptz default now()
) returns jsonb
language plpgsql
stable
set search_path = public, pg_temp
as $$
declare
    v_business uuid := coalesce(p_business_id, app.current_business_id());
    v_setting  config_setting;
    v_value    jsonb;
begin
    select * into v_setting
      from config_setting s
     where s.business_id = v_business and s.key = p_key and s.deleted_at is null;

    if not found then
        return null;
    end if;

    -- Most specific: a value set for this branch, in force at this moment.
    if p_branch_id is not null then
        select o.value into v_value
          from config_branch_override o
         where o.setting_id = v_setting.id
           and o.branch_id = p_branch_id
           and o.deleted_at is null
           and tstzrange(o.effective_from, o.effective_to) @> p_at
         limit 1;
        if v_value is not null then
            return v_value;
        end if;
    end if;

    -- Then the business-wide value in force at this moment.
    select c.value into v_value
      from config_version c
     where c.setting_id = v_setting.id
       and c.deleted_at is null
       and tstzrange(c.effective_from, c.effective_to) @> p_at
     limit 1;
    if v_value is not null then
        return v_value;
    end if;

    -- Then whatever is current, and finally the shipped default. A setting
    -- always resolves to something: a rule with no value is a rule the
    -- application cannot apply, which would fail at the counter.
    return coalesce(v_setting.current_value, v_setting.default_value);
end $$;

comment on function app.config_value(text, uuid, uuid, timestamptz) is
    'Resolves a configured rule: branch override, then business version, then current, then default - each as at the requested moment. Resolution at a past date is what makes BR-15 possible.';

-- Typed readers. The application should not be parsing jsonb at every call
-- site, and a wrong cast should fail here rather than three layers away.
create or replace function app.config_text(p_key text, p_business_id uuid default null,
                                           p_branch_id uuid default null, p_at timestamptz default now())
returns text language sql stable set search_path = public, pg_temp as $$
    select app.config_value(p_key, p_business_id, p_branch_id, p_at) #>> '{}';
$$;

create or replace function app.config_int(p_key text, p_business_id uuid default null,
                                          p_branch_id uuid default null, p_at timestamptz default now())
returns integer language sql stable set search_path = public, pg_temp as $$
    select (app.config_value(p_key, p_business_id, p_branch_id, p_at) #>> '{}')::integer;
$$;

create or replace function app.config_decimal(p_key text, p_business_id uuid default null,
                                              p_branch_id uuid default null, p_at timestamptz default now())
returns numeric language sql stable set search_path = public, pg_temp as $$
    select (app.config_value(p_key, p_business_id, p_branch_id, p_at) #>> '{}')::numeric;
$$;

create or replace function app.config_bool(p_key text, p_business_id uuid default null,
                                           p_branch_id uuid default null, p_at timestamptz default now())
returns boolean language sql stable set search_path = public, pg_temp as $$
    select (app.config_value(p_key, p_business_id, p_branch_id, p_at) #>> '{}')::boolean;
$$;

-- ===========================================================================
-- Permission enforcement, by trigger
-- ===========================================================================
-- In the trigger rather than only in a setter function, so the rule holds for
-- every path into these tables - a future domain service, a bulk import, a
-- console session with a user context. A check that lives in one function is a
-- check that the second caller skips.
create or replace function app.enforce_config_permission()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
    v_required text;
    v_setting  uuid;
begin
    -- No user context: a migration or a seed. Recorded by the audit trail with
    -- a source of console or system (ADR-0008), not silently permitted.
    if app.current_user_id() is null then
        return coalesce(new, old);
    end if;

    if TG_TABLE_NAME = 'config_setting' then
        v_required := coalesce(new.required_permission, old.required_permission);
    else
        v_setting := coalesce(new.setting_id, old.setting_id);
        select s.required_permission into v_required
          from config_setting s where s.id = v_setting;

        -- A version or override pointing at a setting this trigger cannot see
        -- is refused rather than waved through. Without this, anything that
        -- hides the parent row also hides the permission it names.
        if not found then
            raise exception 'refused: no configuration setting % exists to authorise this change', v_setting
                using errcode = 'insufficient_privilege';
        end if;
    end if;

    if v_required is null then
        return coalesce(new, old);
    end if;

    if not app.has_permission(v_required) then
        raise exception 'refused: changing this setting requires the % permission', v_required
            using errcode = 'insufficient_privilege';
    end if;

    return coalesce(new, old);
end $$;

comment on function app.enforce_config_permission() is
    'Refuses a configuration change unless the caller holds the permission the setting itself names. On the trigger rather than in a setter so no write path can skip it.';

drop trigger if exists b_config_setting_permission on config_setting;
create trigger b_config_setting_permission
    before insert or update or delete on config_setting
    for each row execute function app.enforce_config_permission();

drop trigger if exists b_config_version_permission on config_version;
create trigger b_config_version_permission
    before insert or update or delete on config_version
    for each row execute function app.enforce_config_permission();

drop trigger if exists b_config_branch_override_permission on config_branch_override;
create trigger b_config_branch_override_permission
    before insert or update or delete on config_branch_override
    for each row execute function app.enforce_config_permission();

-- ===========================================================================
-- Changing a setting, with history
-- ===========================================================================
create or replace function app.set_config_value(
    p_key            text,
    p_value          jsonb,
    p_effective_from timestamptz default now(),
    p_reason_code    text        default null,
    p_reason_text    text        default null,
    p_business_id    uuid        default null
) returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_business uuid := coalesce(p_business_id, app.current_business_id());
    v_setting  config_setting;
    v_new_id   uuid;
    v_next     timestamptz;
begin
    -- SECURITY DEFINER, so the boundary it bypasses is re-asserted (ADR-0010).
    perform app.assert_tenant_write(v_business, null);

    select * into v_setting
      from config_setting s
     where s.business_id = v_business and s.key = p_key and s.deleted_at is null;

    if not found then
        raise exception 'no such configuration key: %', p_key
            using errcode = 'no_data_found';
    end if;

    if app.current_user_id() is not null and not app.has_permission(v_setting.required_permission) then
        raise exception 'refused: changing % requires the % permission', p_key, v_setting.required_permission
            using errcode = 'insufficient_privilege';
    end if;

    -- Two changes at the same instant are not two states. now() does not move
    -- inside a transaction, so changing the same key twice in one unit of work
    -- would otherwise ask for a zero-width window, which the no-overlap
    -- constraint rightly refuses. The second call corrects the first.
    update config_version
       set value       = p_value,
           changed_by  = app.current_user_id(),
           changed_at  = now(),
           reason_code = coalesce(p_reason_code, reason_code),
           reason_text = coalesce(p_reason_text, reason_text)
     where setting_id = v_setting.id
       and deleted_at is null
       and effective_from = p_effective_from
    returning id, effective_to into v_new_id, v_next;

    if v_new_id is null then
        -- A setting whose value has never been versioned carries no history, so
        -- a resolution at a past date falls through to current_value - which
        -- this call is about to overwrite, and would then answer the past with
        -- the NEW value. Record what was in force beforehand so the past stays
        -- resolvable. This is the difference between BR-15 holding and
        -- appearing to hold.
        if p_effective_from > '-infinity'::timestamptz
           and not exists (select 1 from config_version v
                            where v.setting_id = v_setting.id and v.deleted_at is null)
        then
            insert into config_version (business_id, setting_id, value,
                                        effective_from, effective_to, reason_text)
            values (v_business, v_setting.id,
                    coalesce(v_setting.current_value, v_setting.default_value),
                    '-infinity'::timestamptz, p_effective_from,
                    'the value in force before the first recorded change');
        end if;

        -- Close the value currently in force at that moment rather than
        -- deleting it: the old value must remain resolvable for documents
        -- issued under it.
        update config_version
           set effective_to = p_effective_from
         where setting_id = v_setting.id
           and deleted_at is null
           and tstzrange(effective_from, effective_to) @> p_effective_from
           and effective_from < p_effective_from;

        -- A change already scheduled for a later date still stands. The new
        -- value applies until that one begins, not forever - otherwise setting
        -- a value today would silently collide with next quarter's rate.
        select min(v.effective_from) into v_next
          from config_version v
         where v.setting_id = v_setting.id
           and v.deleted_at is null
           and v.effective_from > p_effective_from;

        insert into config_version (business_id, setting_id, value, effective_from,
                                    effective_to, changed_by, reason_code, reason_text)
        values (v_business, v_setting.id, p_value, p_effective_from,
                v_next, app.current_user_id(), p_reason_code, p_reason_text)
        returning id into v_new_id;
    end if;

    -- current_value caches the value in force NOW, which is not necessarily the
    -- one just written: a change dated in the future must not take effect yet,
    -- and neither must one whose window has already been closed by a later one.
    if p_effective_from <= now() and (v_next is null or v_next > now()) then
        update config_setting set current_value = p_value where id = v_setting.id;
    end if;

    return v_new_id;
end $$;

comment on function app.set_config_value(text, jsonb, timestamptz, text, text, uuid) is
    'Records a new value for a rule from a moment onward, closing the previous one rather than replacing it, and preserving the pre-existing value as history on the first change. A future-dated change does not take effect until its date.';

-- ===========================================================================
-- Tax rate resolution (BR-15)
-- ===========================================================================
create or replace function app.tax_rate_at(
    p_tax_code    text,
    p_on          date default current_date,
    p_business_id uuid default null
) returns numeric
language sql
stable
set search_path = public, pg_temp
as $$
    select r.total_percent
      from tax_rate r
      join tax_code c on c.id = r.tax_code_id
     where c.business_id = coalesce(p_business_id, app.current_business_id())
       and c.code = p_tax_code
       and r.deleted_at is null
       and daterange(r.effective_from, r.effective_to) @> p_on
     limit 1;
$$;

comment on function app.tax_rate_at(text, date, uuid) is
    'The rate in force for a tax code on a given date. Reprinting an old invoice resolves the rate that applied then, never today''s (BR-15).';

-- ===========================================================================
-- CA validation (BR-22)
-- ===========================================================================
-- The hash covers every setting flagged as within the sign-off's scope, at its
-- currently effective value, plus the tax codes and rates. Comparing a stored
-- hash to a freshly computed one means "is the sign-off still valid" is derived
-- rather than remembered - so it cannot drift out of step with the settings it
-- describes, and no trigger has to remember to invalidate it.
--
-- Only the 'tax' domain has a defined fingerprint scope in V1. The table
-- permits 'accounting' and 'payroll' for later; rather than fingerprint them
-- with the tax scope and silently record a sign-off that covers the wrong
-- thing, this refuses. A loud gap beats a quiet lie about what a CA approved.
create or replace function app.config_hash(
    p_domain      text default 'tax',
    p_business_id uuid default null
) returns text
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
    v_business uuid := coalesce(p_business_id, app.current_business_id());
    v_hash     text;
begin
    perform app.assert_tenant_read(v_business);

    if p_domain is distinct from 'tax' then
        raise exception 'no configuration scope is defined for the % validation domain', p_domain
            using errcode = 'feature_not_supported',
                  hint = 'only the tax domain is fingerprinted in V1';
    end if;

    select md5(coalesce(string_agg(part, '|' order by part), ''))
      into v_hash
    from (
        select s.key || '=' ||
               coalesce(app.config_value(s.key, v_business)::text, 'null') as part
          from config_setting s
         where s.business_id = v_business
           and s.is_ca_validated_scope
           and s.deleted_at is null
        union all
        select 'rate:' || c.code || ':' || r.total_percent::text || ':' || r.effective_from::text
          from tax_rate r
          join tax_code c on c.id = r.tax_code_id
         where c.business_id = v_business
           and r.deleted_at is null
        union all
        select 'code:' || c.code || ':' || coalesce(c.hsn_sac, '')
          from tax_code c
         where c.business_id = v_business
           and c.deleted_at is null
    ) parts;

    return v_hash;
end $$;

comment on function app.config_hash(text, uuid) is
    'A fingerprint of the configuration a CA sign-off covers: the in-scope settings at their effective values, plus tax codes and rates. Defined for the tax domain only; refuses the rest rather than fingerprinting the wrong scope.';

create or replace function app.validation_status(
    p_domain      text default 'tax',
    p_business_id uuid default null
) returns text
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
    v_business uuid := coalesce(p_business_id, app.current_business_id());
    v_stored   text;
begin
    -- Reads validation_signoff past row-level security, so the boundary is
    -- re-asserted. Without this, any authenticated caller could ask whether a
    -- competitor's books were signed off (ADR-0011).
    perform app.assert_tenant_read(v_business);

    select v.config_hash into v_stored
      from validation_signoff v
     where v.business_id = v_business and v.domain = p_domain
       and v.is_current and v.deleted_at is null
     limit 1;

    if v_stored is null then
        return 'unvalidated';        -- no sign-off has ever been recorded
    elsif v_stored = app.config_hash(p_domain, v_business) then
        return 'validated';
    else
        return 'stale';              -- signed off, but the configuration moved
    end if;
end $$;

comment on function app.validation_status(text, uuid) is
    'unvalidated, validated or stale. Derived by comparing the stored fingerprint to a fresh one, so a covered setting changing invalidates the sign-off with no trigger needing to remember (BR-22).';

create or replace function app.record_validation_signoff(
    p_domain     text,
    p_by_name    text,
    p_firm       text default null,
    p_reference  text default null,
    p_on         date default current_date,
    p_notes      text default null
) returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_business uuid := app.current_business_id();
    v_id       uuid;
begin
    perform app.assert_tenant_write(v_business, null);

    if app.current_user_id() is not null and not app.has_permission('config.tax.manage') then
        raise exception 'refused: recording a sign-off requires the config.tax.manage permission'
            using errcode = 'insufficient_privilege';
    end if;

    -- A superseded sign-off is kept: what was approved, and when, is part of
    -- the record even after it stops applying.
    update validation_signoff
       set is_current = false, superseded_at = now(),
           superseded_reason = 'replaced by a later sign-off'
     where business_id = v_business and domain = p_domain and is_current and deleted_at is null;

    -- app.config_hash refuses a domain it has no scope for, so a sign-off is
    -- never recorded against a fingerprint that does not describe it.
    insert into validation_signoff (business_id, domain, validated_by_name, firm, reference,
                                    validated_on, config_hash, notes)
    values (v_business, p_domain, p_by_name, p_firm, p_reference,
            p_on, app.config_hash(p_domain, v_business), p_notes)
    returning id into v_id;

    return v_id;
end $$;

comment on function app.record_validation_signoff(text, text, text, text, date, text) is
    'Records a CA sign-off against a fingerprint of the configuration at that moment, superseding rather than deleting the previous one (BR-22).';

-- ===========================================================================
-- BR-22 made visible: tax documents are drafts until validated
-- ===========================================================================
create or replace function app.set_invoice_watermark()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
    -- An issued document does not change its mind. The watermark is decided
    -- when the invoice is written and left alone afterwards, so a sign-off
    -- going stale next year does not retroactively rewrite what was printed.
    -- The one exception is a change of document type, which changes whether
    -- the claim needing validation is being made at all.
    if TG_OP = 'UPDATE' and new.doc_type is not distinct from old.doc_type then
        return new;
    end if;

    if new.doc_type = 'tax_invoice' then
        new.is_draft_watermarked := (app.validation_status('tax', new.business_id) <> 'validated');
    else
        new.is_draft_watermarked := false;
    end if;
    return new;
end $$;

comment on function app.set_invoice_watermark() is
    'Marks a tax invoice as a draft whenever the tax configuration is not currently covered by a CA sign-off. Derived at issue, not remembered (BR-22).';

drop trigger if exists b_invoice_watermark on invoice;
create trigger b_invoice_watermark
    before insert or update of doc_type on invoice
    for each row execute function app.set_invoice_watermark();

-- ===========================================================================
-- Privileges — deliberate, never default (ADR-0010)
-- ===========================================================================
revoke all on function app.assert_tenant_read(uuid) from public, anon, authenticated;
revoke all on function app.has_permission(text) from public, anon, authenticated;
revoke all on function app.config_value(text, uuid, uuid, timestamptz) from public, anon, authenticated;
revoke all on function app.config_text(text, uuid, uuid, timestamptz) from public, anon, authenticated;
revoke all on function app.config_int(text, uuid, uuid, timestamptz) from public, anon, authenticated;
revoke all on function app.config_decimal(text, uuid, uuid, timestamptz) from public, anon, authenticated;
revoke all on function app.config_bool(text, uuid, uuid, timestamptz) from public, anon, authenticated;
revoke all on function app.set_config_value(text, jsonb, timestamptz, text, text, uuid) from public, anon, authenticated;
revoke all on function app.tax_rate_at(text, date, uuid) from public, anon, authenticated;
revoke all on function app.config_hash(text, uuid) from public, anon, authenticated;
revoke all on function app.validation_status(text, uuid) from public, anon, authenticated;
revoke all on function app.record_validation_signoff(text, text, text, text, date, text) from public, anon, authenticated;
revoke all on function app.enforce_config_permission() from public, anon, authenticated;
revoke all on function app.set_invoice_watermark() from public, anon, authenticated;

-- The client reads configuration constantly and must know its own permissions.
grant execute on function app.has_permission(text)                            to authenticated, service_role;
grant execute on function app.config_value(text, uuid, uuid, timestamptz)     to authenticated, service_role;
grant execute on function app.config_text(text, uuid, uuid, timestamptz)      to authenticated, service_role;
grant execute on function app.config_int(text, uuid, uuid, timestamptz)       to authenticated, service_role;
grant execute on function app.config_decimal(text, uuid, uuid, timestamptz)   to authenticated, service_role;
grant execute on function app.config_bool(text, uuid, uuid, timestamptz)      to authenticated, service_role;
grant execute on function app.tax_rate_at(text, date, uuid)                   to authenticated, service_role;
grant execute on function app.validation_status(text, uuid)                   to authenticated, service_role;

-- Writers stay narrower: the owner changes configuration through the app, and
-- the permission trigger applies whichever path is used.
grant execute on function app.set_config_value(text, jsonb, timestamptz, text, text, uuid) to authenticated, service_role;
grant execute on function app.record_validation_signoff(text, text, text, text, date, text) to authenticated, service_role;

-- The hash is machinery, not a client concern. assert_tenant_read is called
-- from inside SECURITY DEFINER functions, never by a client.
grant execute on function app.config_hash(text, uuid)      to service_role;
grant execute on function app.assert_tenant_read(uuid)     to service_role;
