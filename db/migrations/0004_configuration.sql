-- 0004 · Configuration, localisation and tax
--
-- Cluster 2.2 of the blueprint, and the backbone of AP-1: "any business rule a
-- shop owner could reasonably want to change is data, not code."
--
-- Three things live here that are easy to under-build and expensive to retrofit:
--   * the configuration registry, with permissions, versioning and effective
--     dating, so a rule change is auditable and a past document can be
--     reproduced with the rule that was in force at the time (BR-15, BR-18);
--   * the localisation layer for tenant data, so garment types and reason codes
--     can be shown in Hindi without a schema change (decision 3);
--   * the CA validation record, which gates P3 production use (BR-22).
--
-- This migration creates tables and their integrity constraints only. The
-- resolver functions, the seeded key set and the sign-off logic belong to WP-6.

-- ===========================================================================
-- Localisation
-- ===========================================================================
create table locale (
    id                uuid primary key default gen_random_uuid(),
    business_id       uuid not null references business(id),

    code              text not null,
    name              text not null,
    native_name       text,
    -- Urdu is right-to-left. Carrying direction from the start means the layout
    -- work is a rendering concern later, not a schema change (decision 3).
    direction         text not null default 'ltr'
        constraint locale_direction_valid check (direction in ('ltr','rtl')),
    is_active         boolean not null default true,
    is_default        boolean not null default false,
    sort_order        integer not null default 100,

    created_at        timestamptz not null default now(),
    created_by        uuid,
    updated_at        timestamptz not null default now(),
    updated_by        uuid,
    deleted_at        timestamptz,
    row_version       integer not null default 1,

    constraint locale_code_unique_per_business unique nulls not distinct (business_id, code, deleted_at)
);

comment on table locale is 'Languages this business operates in. V1 activates English; Hindi is architecturally present from P0.';

-- Exactly one default locale per business, enforced rather than assumed.
create unique index locale_single_default on locale (business_id)
    where is_default and deleted_at is null;

select app.attach_standard_triggers('locale');

create table translation (
    id                uuid primary key default gen_random_uuid(),
    business_id       uuid not null references business(id),

    -- Generic by design: one table serves garment type names, measurement field
    -- labels, status labels, reason codes and notification wording. Application
    -- chrome is translated in the Flutter message catalogues; this table exists
    -- for data the tenant owns and can add to.
    entity_type       text not null,
    entity_id         uuid not null,
    field             text not null,
    locale_code       text not null,
    text_value        text not null,

    created_at        timestamptz not null default now(),
    created_by        uuid,
    updated_at        timestamptz not null default now(),
    updated_by        uuid,
    deleted_at        timestamptz,
    row_version       integer not null default 1,

    constraint translation_unique unique nulls not distinct (entity_type, entity_id, field, locale_code, deleted_at)
);

comment on table translation is
    'Translations for tenant-owned data labels. App chrome is translated in the client message catalogues; this covers what the owner creates.';

create index translation_lookup_idx on translation (entity_type, entity_id, locale_code) where deleted_at is null;
select app.attach_standard_triggers('translation');

-- ===========================================================================
-- Configuration registry — AP-1 / BR-21
-- ===========================================================================
create table config_setting (
    id                    uuid primary key default gen_random_uuid(),
    business_id           uuid not null references business(id),

    key                   text not null,
    category              text not null,
    scope                 text not null default 'business'
        constraint config_setting_scope_valid check (scope in ('business','branch')),
    value_type            text not null
        constraint config_setting_type_valid check (value_type in ('boolean','integer','decimal','text','date','json','enum')),
    default_value         jsonb not null,
    current_value         jsonb,
    allowed_values        jsonb,
    -- The permission required to change it. An owner-only setting and a
    -- manager-adjustable one differ by this column, not by a hard-coded check.
    required_permission   text not null,
    is_effective_dated    boolean not null default false,
    -- Settings covered by the CA sign-off (BR-22). Changing one of these
    -- invalidates the sign-off and restores the unvalidated banner.
    is_ca_validated_scope boolean not null default false,
    description           text,

    created_at            timestamptz not null default now(),
    created_by            uuid,
    updated_at            timestamptz not null default now(),
    updated_by            uuid,
    deleted_at            timestamptz,
    row_version           integer not null default 1,

    constraint config_setting_key_unique_per_business unique nulls not distinct (business_id, key, deleted_at)
);

comment on table config_setting is
    'The registry of every owner-controllable rule (AP-1, BR-21). A literal threshold or rate in application code is a defect.';
comment on column config_setting.is_ca_validated_scope is
    'True where the setting is covered by the CA sign-off; changing it invalidates that sign-off (BR-22).';

select app.attach_standard_triggers('config_setting');

create table config_version (
    id                uuid primary key default gen_random_uuid(),
    business_id       uuid not null references business(id),

    setting_id        uuid not null references config_setting(id),
    value             jsonb not null,
    effective_from    timestamptz not null default now(),
    effective_to      timestamptz,

    changed_by        uuid references app_user(id),
    changed_at        timestamptz not null default now(),
    reason_code       text,
    reason_text       text,

    created_at        timestamptz not null default now(),
    created_by        uuid,
    updated_at        timestamptz not null default now(),
    updated_by        uuid,
    deleted_at        timestamptz,
    row_version       integer not null default 1,

    constraint config_version_range_valid check (effective_to is null or effective_to > effective_from)
);

comment on table config_version is
    'Every value a setting has ever held, with the window it applied in. This is what lets a past document be reproduced under the rule in force then (BR-15).';

-- Two values cannot apply to the same setting at the same moment. Enforced by
-- the database because every effective-dated lookup depends on it.
alter table config_version
    add constraint config_version_no_overlap
    exclude using gist (
        setting_id with =,
        tstzrange(effective_from, effective_to) with &&
    ) where (deleted_at is null);

create index config_version_setting_idx on config_version (setting_id, effective_from desc) where deleted_at is null;
select app.attach_standard_triggers('config_version');

create table config_branch_override (
    id                uuid primary key default gen_random_uuid(),
    business_id       uuid not null references business(id),
    branch_id         uuid not null references branch(id),

    setting_id        uuid not null references config_setting(id),
    value             jsonb not null,
    effective_from    timestamptz not null default now(),
    effective_to      timestamptz,

    created_at        timestamptz not null default now(),
    created_by        uuid,
    updated_at        timestamptz not null default now(),
    updated_by        uuid,
    deleted_at        timestamptz,
    row_version       integer not null default 1,

    constraint config_branch_override_range_valid check (effective_to is null or effective_to > effective_from)
);

comment on table config_branch_override is
    'A branch-level value for a setting whose scope allows it. Absent means the business value applies.';

alter table config_branch_override
    add constraint config_branch_override_no_overlap
    exclude using gist (
        setting_id with =,
        branch_id with =,
        tstzrange(effective_from, effective_to) with &&
    ) where (deleted_at is null);

select app.attach_standard_triggers('config_branch_override');

-- ===========================================================================
-- reason_code — controlled lists, owned by the business (AP-1, BR-13)
-- ===========================================================================
create table reason_code (
    id                uuid primary key default gen_random_uuid(),
    business_id       uuid not null references business(id),

    domain            text not null
        constraint reason_code_domain_valid check (domain in (
            'discount','price_override','order_cancellation','date_override',
            'stock_adjustment','stock_wastage','payment_reversal','refund',
            'measurement_change','alteration','wage_adjustment','permission_change',
            'number_void','material_writeoff','other')),
    code              text not null,
    label             text not null,
    requires_text     boolean not null default false,
    is_active         boolean not null default true,
    sort_order        integer not null default 100,

    created_at        timestamptz not null default now(),
    created_by        uuid,
    updated_at        timestamptz not null default now(),
    updated_by        uuid,
    deleted_at        timestamptz,
    row_version       integer not null default 1,

    constraint reason_code_unique unique nulls not distinct (business_id, domain, code, deleted_at)
);

comment on table reason_code is
    'The controlled lists behind every "why did you do that" prompt. The owner edits them; the domains they attach to are fixed.';

select app.attach_standard_triggers('reason_code');

-- ===========================================================================
-- Tax configuration — data, never constants (BR-15, BR-22)
-- ===========================================================================
create table tax_profile (
    id                  uuid primary key default gen_random_uuid(),
    business_id         uuid not null references business(id),
    branch_id           uuid references branch(id),

    registration_type   text not null
        constraint tax_profile_registration_valid check (registration_type in ('regular','composition','unregistered')),
    gstin               text,
    legal_name          text,
    place_of_supply     text,
    effective_from      date not null,
    effective_to        date,
    is_active           boolean not null default true,

    created_at          timestamptz not null default now(),
    created_by          uuid,
    updated_at          timestamptz not null default now(),
    updated_by          uuid,
    deleted_at          timestamptz,
    row_version         integer not null default 1,

    constraint tax_profile_range_valid check (effective_to is null or effective_to > effective_from)
);

comment on table tax_profile is
    'The tax identity in force for a business or a branch over a period. Per-branch GSTIN is supported from day one (decision 2).';

select app.attach_standard_triggers('tax_profile');

create table tax_code (
    id                uuid primary key default gen_random_uuid(),
    business_id       uuid not null references business(id),

    code              text not null,
    kind              text not null
        constraint tax_code_kind_valid check (kind in ('service','goods')),
    hsn_sac           text,
    description       text,
    is_active         boolean not null default true,

    created_at        timestamptz not null default now(),
    created_by        uuid,
    updated_at        timestamptz not null default now(),
    updated_by        uuid,
    deleted_at        timestamptz,
    row_version       integer not null default 1,

    constraint tax_code_unique unique nulls not distinct (business_id, code, deleted_at)
);

comment on table tax_code is
    'A tax classification with its HSN or SAC code. Stitching is a service; fabric is goods; the rates attached to each are configuration.';

select app.attach_standard_triggers('tax_code');

create table tax_rate (
    id                uuid primary key default gen_random_uuid(),
    business_id       uuid not null references business(id),

    tax_code_id       uuid not null references tax_code(id),
    total_percent     app.rate_percent not null
        constraint tax_rate_percent_sane check (total_percent >= 0 and total_percent <= 100),
    effective_from    date not null,
    effective_to      date,
    note              text,

    created_at        timestamptz not null default now(),
    created_by        uuid,
    updated_at        timestamptz not null default now(),
    updated_by        uuid,
    deleted_at        timestamptz,
    row_version       integer not null default 1,

    constraint tax_rate_range_valid check (effective_to is null or effective_to > effective_from)
);

comment on table tax_rate is
    'A rate and the window it applies in. Reprinting a two-year-old invoice uses the row that was in force then, never today''s (BR-15).';

-- One rate per code at any moment. Without this, "the rate in force" is
-- ambiguous and BR-15 cannot be honoured.
alter table tax_rate
    add constraint tax_rate_no_overlap
    exclude using gist (
        tax_code_id with =,
        daterange(effective_from, effective_to) with &&
    ) where (deleted_at is null);

select app.attach_standard_triggers('tax_rate');

create table tax_rate_component (
    id                uuid primary key default gen_random_uuid(),
    business_id       uuid not null references business(id),

    tax_rate_id       uuid not null references tax_rate(id),
    component         text not null
        constraint tax_rate_component_valid check (component in ('CGST','SGST','IGST','UTGST','CESS')),
    percent           app.rate_percent not null
        constraint tax_rate_component_percent_sane check (percent >= 0 and percent <= 100),

    created_at        timestamptz not null default now(),
    created_by        uuid,
    updated_at        timestamptz not null default now(),
    updated_by        uuid,
    deleted_at        timestamptz,
    row_version       integer not null default 1,

    constraint tax_rate_component_unique unique nulls not distinct (tax_rate_id, component, deleted_at)
);

comment on table tax_rate_component is
    'The split a rate breaks into on an invoice. Intra-state work splits CGST and SGST; inter-state uses IGST.';

select app.attach_standard_triggers('tax_rate_component');

-- ===========================================================================
-- price_list — headers here; the per-garment lines arrive with the catalogue
-- ===========================================================================
create table price_list (
    id                uuid primary key default gen_random_uuid(),
    business_id       uuid not null references business(id),
    branch_id         uuid references branch(id),

    code              text not null,
    name              text not null,
    currency_code     text not null default 'INR',
    -- Whether the prices in this list already include tax. Both are supported
    -- because both are used in practice, and the choice changes every line
    -- calculation on an invoice.
    pricing_mode      text not null default 'exclusive'
        constraint price_list_pricing_mode_valid check (pricing_mode in ('inclusive','exclusive')),
    is_default        boolean not null default false,
    effective_from    date not null,
    effective_to      date,

    created_at        timestamptz not null default now(),
    created_by        uuid,
    updated_at        timestamptz not null default now(),
    updated_by        uuid,
    deleted_at        timestamptz,
    row_version       integer not null default 1,

    constraint price_list_code_unique unique nulls not distinct (business_id, code, deleted_at),
    constraint price_list_range_valid check (effective_to is null or effective_to > effective_from)
);

comment on table price_list is
    'A set of prices with a validity window. branch_id null means it applies business-wide; a branch row overrides it.';

select app.attach_standard_triggers('price_list');

-- ===========================================================================
-- notification_template — wording is configuration, not code
-- ===========================================================================
create table notification_template (
    id                uuid primary key default gen_random_uuid(),
    business_id       uuid not null references business(id),

    event_key         text not null,
    channel           text not null
        constraint notification_template_channel_valid check (channel in ('whatsapp','sms','email','in_app')),
    locale_code       text not null,
    subject           text,
    body              text not null,
    is_active         boolean not null default true,

    created_at        timestamptz not null default now(),
    created_by        uuid,
    updated_at        timestamptz not null default now(),
    updated_by        uuid,
    deleted_at        timestamptz,
    row_version       integer not null default 1,

    constraint notification_template_unique unique nulls not distinct (business_id, event_key, channel, locale_code, deleted_at)
);

comment on table notification_template is
    'What a customer message says, per event, channel and language. Editable by the owner without a release (AP-1).';

select app.attach_standard_triggers('notification_template');

-- ===========================================================================
-- validation_signoff — the CA gate (BR-22)
-- ===========================================================================
create table validation_signoff (
    id                uuid primary key default gen_random_uuid(),
    business_id       uuid not null references business(id),

    domain            text not null
        constraint validation_signoff_domain_valid check (domain in ('tax','accounting','payroll')),
    validated_by_name text not null,
    firm              text,
    reference         text,
    validated_on      date not null,
    -- A hash of exactly the settings that were approved. If a covered setting
    -- changes afterwards, the hash no longer matches and the sign-off ceases to
    -- cover the current configuration (BR-22).
    config_hash       text not null,
    notes             text,
    is_current        boolean not null default true,
    superseded_at     timestamptz,
    superseded_reason text,

    created_at        timestamptz not null default now(),
    created_by        uuid,
    updated_at        timestamptz not null default now(),
    updated_by        uuid,
    deleted_at        timestamptz,
    row_version       integer not null default 1
);

comment on table validation_signoff is
    'A qualified CA''s approval of the tax and accounting configuration, hashed against what was approved. Until a current row exists, the system runs unvalidated and tax documents are watermarked as drafts (BR-22).';

create unique index validation_signoff_one_current_per_domain on validation_signoff (business_id, domain)
    where is_current and deleted_at is null;

select app.attach_standard_triggers('validation_signoff');
