-- 0005 · Customers, households, catalogue and measurements
--
-- Cluster 2.3 of the blueprint. The part of the system a counter employee
-- touches fifty times a day, and the part where the v0.1 design was wrong.
--
-- Identity (decision recorded at v0.2): a customer is a permanent UUID with a
-- readable code. Phone numbers are child rows -- zero, one or six per person,
-- shareable between family members, correctable, never unique. Nothing about a
-- person's identity depends on a number they might change.
--
-- Measurements are four levels, each with a different job (BR-01):
--   template  the fields for a garment type, versioned
--   profile   a named set for one customer and garment type
--   revision  an append-only measurement event
--   snapshot  a deep copy frozen onto a garment, with no live link back

-- ===========================================================================
-- household — families are the normal case, not an edge case
-- ===========================================================================
create table household (
    id                uuid primary key default gen_random_uuid(),
    business_id       uuid not null references business(id),

    name              text not null,
    address_line1     text,
    address_line2     text,
    city              text,
    postal_code       text,
    notes             text,

    created_at        timestamptz not null default now(),
    created_by        uuid,
    updated_at        timestamptz not null default now(),
    updated_by        uuid,
    deleted_at        timestamptz,
    row_version       integer not null default 1
);

comment on table household is
    'A family or group served together. A lookup and a grouping - never a second ledger account. Members hold their own measurements, history and balances.';

create index household_business_idx on household (business_id) where deleted_at is null;
create index household_name_trgm on household using gin (name gin_trgm_ops);
select app.attach_standard_triggers('household');

-- ===========================================================================
-- customer — the permanent identity
-- ===========================================================================
create table customer (
    id                  uuid primary key default gen_random_uuid(),
    business_id         uuid not null references business(id),

    -- Readable, business-scoped, printed on job cards and read aloud on the
    -- phone. Generated in WP-6 from a number series; supplied here.
    customer_code       text,
    display_name        text not null,
    -- Lower-cased, punctuation-stripped form used for trigram search and for
    -- duplicate scoring. Maintained by the application, not by a trigger, so the
    -- normalisation rule can change without a migration.
    name_normalized     text,
    given_name          text,
    family_name         text,
    -- Drives which garment types and measurement templates are offered. A
    -- domain attribute of tailoring, not a demographic record.
    gender              text
        constraint customer_gender_valid check (gender in ('male','female','other','unspecified')),
    date_of_birth       date,

    -- Where they were first served. Customers belong to the business, not to a
    -- branch: branch-scoping customers is what creates the duplicate problem.
    first_seen_branch_id uuid references branch(id),
    preferred_branch_id  uuid references branch(id),
    preferred_locale     text,
    notes                text,

    status              text not null default 'active'
        constraint customer_status_valid check (status in ('active','merged','archived')),
    -- A merged record is never deleted. It survives, marked, and redirects, so
    -- historical job cards and invoices never break (BR-12).
    merged_into_id      uuid references customer(id),

    created_at          timestamptz not null default now(),
    created_by          uuid,
    updated_at          timestamptz not null default now(),
    updated_by          uuid,
    deleted_at          timestamptz,
    row_version         integer not null default 1,

    -- A merged customer must point somewhere, and a live one must not.
    constraint customer_merge_state_coherent check (
        (status = 'merged' and merged_into_id is not null) or
        (status <> 'merged' and merged_into_id is null)
    ),
    constraint customer_not_merged_into_self check (merged_into_id is null or merged_into_id <> id)
);

comment on table customer is
    'A person. Identity is the uuid; the phone is an attribute (§2.3). Business-scoped, so one record serves every branch.';
comment on column customer.merged_into_id is
    'Set when this record was merged into another. The row survives and redirects (BR-12); unmerge is mechanical because every moved row is stamped.';

-- A partial unique index rather than UNIQUE NULLS NOT DISTINCT: a customer
-- whose readable code has not been assigned yet must not collide with every
-- other customer in the same position.
create unique index customer_code_unique_per_business on customer (business_id, customer_code)
    where deleted_at is null;

create index customer_business_idx on customer (business_id) where deleted_at is null and status = 'active';
create index customer_name_trgm on customer using gin (name_normalized gin_trgm_ops);
create index customer_dob_idx on customer (business_id, date_of_birth) where deleted_at is null;
select app.attach_standard_triggers('customer');

create table household_member (
    id                  uuid primary key default gen_random_uuid(),
    business_id         uuid not null references business(id),

    household_id        uuid not null references household(id),
    customer_id         uuid not null references customer(id),
    relation            text
        constraint household_member_relation_valid check (relation in
            ('head','spouse','son','daughter','father','mother','sibling','other')),
    is_primary_contact  boolean not null default false,

    created_at          timestamptz not null default now(),
    created_by          uuid,
    updated_at          timestamptz not null default now(),
    updated_by          uuid,
    deleted_at          timestamptz,
    row_version         integer not null default 1,

    constraint household_member_unique unique nulls not distinct (household_id, customer_id, deleted_at)
);

comment on table household_member is
    'Membership of a household, with a relation label. A join table from day one so shared households are a dropped index later, not a restructure.';

-- V1 constraint: one household per customer. Dropping this index is the whole
-- migration needed if a customer ever has to belong to two households.
create unique index household_member_one_per_customer on household_member (customer_id)
    where deleted_at is null;

create index household_member_household_idx on household_member (household_id) where deleted_at is null;
select app.attach_standard_triggers('household_member');

-- ===========================================================================
-- customer_contact — phone numbers are attributes, never identity
-- ===========================================================================
create table customer_contact (
    id                uuid primary key default gen_random_uuid(),
    business_id       uuid not null references business(id),

    -- Exactly one of customer_id or household_id. A number shared by a family
    -- can hang off the household; a member with their own number has their own
    -- row. Resolution prefers the member's own contact.
    customer_id       uuid references customer(id),
    household_id      uuid references household(id),

    kind              text not null default 'mobile'
        constraint customer_contact_kind_valid check (kind in ('mobile','whatsapp','landline','email','other')),
    value_raw         text not null,
    -- Normalised form used for search and duplicate scoring. Deliberately not
    -- unique: family members share numbers, and that is not an error.
    value_e164        text,
    label             text,
    is_primary        boolean not null default false,
    is_verified       boolean not null default false,
    verified_at       timestamptz,

    created_at        timestamptz not null default now(),
    created_by        uuid,
    updated_at        timestamptz not null default now(),
    updated_by        uuid,
    deleted_at        timestamptz,
    row_version       integer not null default 1,

    constraint customer_contact_owner_exactly_one check (
        (customer_id is not null and household_id is null) or
        (customer_id is null and household_id is not null)
    )
);

comment on table customer_contact is
    'A way to reach someone. Never unique: two people may share a number, one person may have six, and a person may have none (§2.3).';

create index customer_contact_e164_idx on customer_contact (business_id, value_e164) where deleted_at is null;
create index customer_contact_customer_idx on customer_contact (customer_id) where deleted_at is null;
create index customer_contact_household_idx on customer_contact (household_id) where deleted_at is null;
-- One primary contact per customer, enforced rather than hoped for.
create unique index customer_contact_one_primary on customer_contact (customer_id)
    where is_primary and customer_id is not null and deleted_at is null;
select app.attach_standard_triggers('customer_contact');

-- ===========================================================================
-- Duplicate detection and merge — recorded, redirecting, reversible
-- ===========================================================================
create table duplicate_candidate (
    id                uuid primary key default gen_random_uuid(),
    business_id       uuid not null references business(id),

    customer_a_id     uuid not null references customer(id),
    customer_b_id     uuid not null references customer(id),
    score             numeric(4,3) not null
        constraint duplicate_candidate_score_range check (score >= 0 and score <= 1),
    -- Which signals fired and what each contributed, so a reviewer sees why the
    -- pair was suggested rather than being asked to trust a number.
    reasons           jsonb not null default '{}'::jsonb,
    detected_by       text not null default 'nightly'
        constraint duplicate_candidate_detected_by_valid check (detected_by in ('live','nightly','staff')),

    status            text not null default 'open'
        constraint duplicate_candidate_status_valid check (status in ('open','merged','dismissed')),
    reviewed_by       uuid references app_user(id),
    reviewed_at       timestamptz,
    dismissed_reason  text,

    created_at        timestamptz not null default now(),
    created_by        uuid,
    updated_at        timestamptz not null default now(),
    updated_by        uuid,
    deleted_at        timestamptz,
    row_version       integer not null default 1,

    -- A pair is a pair regardless of order, and a record cannot duplicate itself.
    constraint duplicate_candidate_ordered check (customer_a_id < customer_b_id)
);

comment on table duplicate_candidate is
    'A suggested duplicate awaiting human review. Nothing merges automatically: wrongly merging two family members who share a number is far worse than a duplicate (§2.3).';

create unique index duplicate_candidate_pair_unique on duplicate_candidate (customer_a_id, customer_b_id)
    where status = 'open' and deleted_at is null;
select app.attach_standard_triggers('duplicate_candidate');

create table customer_merge (
    id                uuid primary key default gen_random_uuid(),
    business_id       uuid not null references business(id),

    surviving_id      uuid not null references customer(id),
    merged_id         uuid not null references customer(id),
    performed_by      uuid references app_user(id),
    performed_at      timestamptz not null default now(),
    reason_code       text,
    reason_text       text,
    -- Which rows moved, and the field-level choices a human made. This payload
    -- is what makes unmerge mechanical rather than a rescue operation.
    moved_rows        jsonb not null default '{}'::jsonb,
    field_choices     jsonb not null default '{}'::jsonb,

    unmerged_at       timestamptz,
    unmerged_by       uuid references app_user(id),
    unmerge_reason    text,

    created_at        timestamptz not null default now(),
    created_by        uuid,
    updated_at        timestamptz not null default now(),
    updated_by        uuid,
    deleted_at        timestamptz,
    row_version       integer not null default 1,

    constraint customer_merge_distinct check (surviving_id <> merged_id)
);

comment on table customer_merge is
    'A merge event, with everything needed to reverse it. Merges get done wrong; the design assumes it.';

select app.attach_standard_triggers('customer_merge');

-- ===========================================================================
-- Catalogue — garment types, styles, prices
-- ===========================================================================
create table garment_type (
    id                    uuid primary key default gen_random_uuid(),
    business_id           uuid not null references business(id),

    code                  text not null,
    name                  text not null,
    gender_applicability  text not null default 'any'
        constraint garment_type_gender_valid check (gender_applicability in ('any','male','female')),
    default_turnaround_days smallint,
    requires_trial        boolean not null default false,
    is_active             boolean not null default true,
    sort_order            integer not null default 100,

    created_at            timestamptz not null default now(),
    created_by            uuid,
    updated_at            timestamptz not null default now(),
    updated_by            uuid,
    deleted_at            timestamptz,
    row_version           integer not null default 1,

    constraint garment_type_code_unique unique nulls not distinct (business_id, code, deleted_at)
);

comment on table garment_type is
    'Shirt, kurta, blouse, lehenga, blazer. Owner-configurable (AP-1); names are translated via the translation table, not duplicated per language.';

select app.attach_standard_triggers('garment_type');

create table style_option_group (
    id                uuid primary key default gen_random_uuid(),
    business_id       uuid not null references business(id),

    garment_type_id   uuid not null references garment_type(id),
    code              text not null,
    label             text not null,
    selection_type    text not null default 'single'
        constraint style_option_group_selection_valid check (selection_type in ('single','multi')),
    is_required       boolean not null default false,
    sort_order        integer not null default 100,

    created_at        timestamptz not null default now(),
    created_by        uuid,
    updated_at        timestamptz not null default now(),
    updated_by        uuid,
    deleted_at        timestamptz,
    row_version       integer not null default 1,

    constraint style_option_group_unique unique nulls not distinct (garment_type_id, code, deleted_at)
);

comment on table style_option_group is
    'Collar, cuff, pocket, neck, sleeve - the choices that make a garment this garment. Configurable per type.';

select app.attach_standard_triggers('style_option_group');

create table style_option (
    id                uuid primary key default gen_random_uuid(),
    business_id       uuid not null references business(id),

    group_id          uuid not null references style_option_group(id),
    code              text not null,
    label             text not null,
    -- A style that costs more says so here rather than in a pricing rule buried
    -- in code (AP-1).
    price_delta       app.money_amount not null default 0,
    extra_minutes     integer not null default 0,
    is_active         boolean not null default true,
    sort_order        integer not null default 100,

    created_at        timestamptz not null default now(),
    created_by        uuid,
    updated_at        timestamptz not null default now(),
    updated_by        uuid,
    deleted_at        timestamptz,
    row_version       integer not null default 1,

    constraint style_option_unique unique nulls not distinct (group_id, code, deleted_at)
);

comment on column style_option.extra_minutes is
    'Standard minutes this choice adds, feeding the capacity engine: a hand-worked collar is not the same job as a plain one.';
comment on table style_option is 'One choice within a style group, with its price and time effect.';

select app.attach_standard_triggers('style_option');

create table price_list_item (
    id                uuid primary key default gen_random_uuid(),
    business_id       uuid not null references business(id),

    price_list_id     uuid not null references price_list(id),
    garment_type_id   uuid not null references garment_type(id),
    unit_price        app.money_amount not null
        constraint price_list_item_price_non_negative check (unit_price >= 0),
    tax_code_id       uuid references tax_code(id),
    is_active         boolean not null default true,

    created_at        timestamptz not null default now(),
    created_by        uuid,
    updated_at        timestamptz not null default now(),
    updated_by        uuid,
    deleted_at        timestamptz,
    row_version       integer not null default 1,

    constraint price_list_item_unique unique nulls not distinct (price_list_id, garment_type_id, deleted_at)
);

comment on table price_list_item is
    'What a garment type costs in a given price list, and which tax classification applies to it.';

select app.attach_standard_triggers('price_list_item');

-- ===========================================================================
-- Measurements — four levels (BR-01)
-- ===========================================================================
create table measurement_template (
    id                uuid primary key default gen_random_uuid(),
    business_id       uuid not null references business(id),

    garment_type_id   uuid not null references garment_type(id),
    version           integer not null default 1,
    is_current        boolean not null default true,
    effective_from    timestamptz not null default now(),
    note              text,

    created_at        timestamptz not null default now(),
    created_by        uuid,
    updated_at        timestamptz not null default now(),
    updated_by        uuid,
    deleted_at        timestamptz,
    row_version       integer not null default 1,

    constraint measurement_template_version_unique unique nulls not distinct (garment_type_id, version, deleted_at)
);

comment on table measurement_template is
    'The field set for a garment type, versioned. Adding a custom field creates a new version; existing revisions and snapshots are untouched.';

create unique index measurement_template_one_current on measurement_template (garment_type_id)
    where is_current and deleted_at is null;
select app.attach_standard_triggers('measurement_template');

create table template_field (
    id                uuid primary key default gen_random_uuid(),
    business_id       uuid not null references business(id),

    template_id       uuid not null references measurement_template(id),
    code              text not null,
    label             text not null,
    unit              text not null default 'inch'
        constraint template_field_unit_valid check (unit in ('inch','cm','none')),
    input_type        text not null default 'decimal'
        constraint template_field_input_valid check (input_type in ('decimal','fraction','integer','select','text','boolean')),
    -- Sanity range for the delta check on entry. Soft warnings, never blocking:
    -- an unusual body is not a data error.
    min_value         numeric(8,3),
    max_value         numeric(8,3),
    is_required       boolean not null default false,
    group_name        text,
    help_text         text,
    display_order     integer not null default 100,

    created_at        timestamptz not null default now(),
    created_by        uuid,
    updated_at        timestamptz not null default now(),
    updated_by        uuid,
    deleted_at        timestamptz,
    row_version       integer not null default 1,

    constraint template_field_code_unique unique nulls not distinct (template_id, code, deleted_at),
    constraint template_field_range_sane check (min_value is null or max_value is null or max_value >= min_value)
);

comment on table template_field is
    'One measurement field. Labels are translated via the translation table so a Hindi label is data, not a second column.';

select app.attach_standard_triggers('template_field');

create table measurement_profile (
    id                uuid primary key default gen_random_uuid(),
    business_id       uuid not null references business(id),

    customer_id       uuid not null references customer(id),
    garment_type_id   uuid not null references garment_type(id),
    name              text not null default 'regular',
    is_default        boolean not null default true,
    notes             text,

    created_at        timestamptz not null default now(),
    created_by        uuid,
    updated_at        timestamptz not null default now(),
    updated_by        uuid,
    deleted_at        timestamptz,
    row_version       integer not null default 1,

    constraint measurement_profile_unique unique nulls not distinct (customer_id, garment_type_id, name, deleted_at)
);

comment on table measurement_profile is
    'A named measurement set for one customer and garment type - "regular", "loose". A customer may have several.';

create unique index measurement_profile_one_default on measurement_profile (customer_id, garment_type_id)
    where is_default and deleted_at is null;
select app.attach_standard_triggers('measurement_profile');

create table measurement_revision (
    id                uuid primary key default gen_random_uuid(),
    business_id       uuid not null references business(id),

    profile_id        uuid not null references measurement_profile(id),
    template_id       uuid not null references measurement_template(id),
    revision_no       integer not null,
    unit              text not null default 'inch'
        constraint measurement_revision_unit_valid check (unit in ('inch','cm')),
    -- Where the numbers came from. An unusual set measured from a sample garment
    -- is a different thing from one given over the phone, and the difference
    -- matters when a garment does not fit.
    source            text not null default 'measured_in_store'
        constraint measurement_revision_source_valid check (source in
            ('measured_in_store','copied_from_previous','from_sample_garment',
             'customer_provided','alteration_derived','imported')),
    taken_by          uuid references app_user(id),
    taken_at          timestamptz not null default now(),
    notes             text,
    is_current        boolean not null default true,
    -- Denormalised copy of the values for fast rendering. The typed rows in
    -- measurement_value remain the queryable truth.
    values_cache      jsonb not null default '{}'::jsonb,

    created_at        timestamptz not null default now(),
    created_by        uuid,
    updated_at        timestamptz not null default now(),
    updated_by        uuid,
    deleted_at        timestamptz,
    row_version       integer not null default 1,

    constraint measurement_revision_no_unique unique nulls not distinct (profile_id, revision_no, deleted_at)
);

comment on table measurement_revision is
    'An append-only measurement event. Corrections create a revision; they never overwrite one. Two devices measuring the same person produce two revisions and lose nothing (§5.2).';

create unique index measurement_revision_one_current on measurement_revision (profile_id)
    where is_current and deleted_at is null;
select app.attach_standard_triggers('measurement_revision');

create table measurement_value (
    id                uuid primary key default gen_random_uuid(),
    business_id       uuid not null references business(id),

    revision_id       uuid not null references measurement_revision(id),
    field_code        text not null,
    value_numeric     numeric(8,3),
    value_text        text,

    created_at        timestamptz not null default now(),
    created_by        uuid,
    updated_at        timestamptz not null default now(),
    updated_by        uuid,
    deleted_at        timestamptz,
    row_version       integer not null default 1,

    constraint measurement_value_unique unique nulls not distinct (revision_id, field_code, deleted_at),
    constraint measurement_value_has_a_value check (value_numeric is not null or value_text is not null)
);

comment on table measurement_value is
    'The typed, queryable form of a revision. Analytics and the duplicate-scoring signal read these rows, not the JSON cache.';

create index measurement_value_revision_idx on measurement_value (revision_id) where deleted_at is null;
select app.attach_standard_triggers('measurement_value');

create table measurement_snapshot (
    id                uuid primary key default gen_random_uuid(),
    business_id       uuid not null references business(id),

    -- The garment this was frozen onto. The foreign key is added in 0006, where
    -- garment is created; the column lives here because the snapshot belongs to
    -- the measurement story, not the production one.
    garment_id        uuid,
    -- Informational only. Deliberately NOT a live path to the values: if this
    -- revision is later corrected, the garment keeps the numbers it was cut to
    -- (BR-01).
    source_revision_id uuid references measurement_revision(id),
    template_id       uuid not null references measurement_template(id),
    template_version  integer not null,
    unit              text not null,
    source            text not null,
    values_frozen     jsonb not null,
    frozen_at         timestamptz not null default now(),
    frozen_by         uuid references app_user(id),

    -- Set when a garment's measurements were revised after freezing, which
    -- requires manager approval once cutting has begun (BR-01).
    replaced_snapshot_id uuid references measurement_snapshot(id),
    replace_reason_code  text,
    replace_reason_text  text,

    created_at        timestamptz not null default now(),
    created_by        uuid,
    updated_at        timestamptz not null default now(),
    updated_by        uuid,
    deleted_at        timestamptz,
    row_version       integer not null default 1,

    constraint measurement_snapshot_values_not_empty check (values_frozen <> '{}'::jsonb)
);

comment on table measurement_snapshot is
    'A deep copy of the measurements a garment was cut to, with no live link back to the profile. This table is why BR-01 is a guarantee rather than an intention.';
comment on column measurement_snapshot.source_revision_id is
    'Informational provenance only. The values are in values_frozen and are never read through this reference.';

create index measurement_snapshot_garment_idx on measurement_snapshot (garment_id) where deleted_at is null;
select app.attach_standard_triggers('measurement_snapshot');

-- ===========================================================================
-- attachment — one table for every photo, signature and document
-- ===========================================================================
create table attachment (
    id                uuid primary key default gen_random_uuid(),
    business_id       uuid not null references business(id),
    branch_id         uuid references branch(id),

    entity_type       text not null,
    entity_id         uuid not null,
    kind              text not null
        constraint attachment_kind_valid check (kind in
            ('reference_photo','sample_garment','fabric_photo','style_reference',
             'delivery_proof','signature','document','other')),
    storage_path      text,
    mime_type         text,
    byte_size         bigint,
    caption           text,
    captured_at       timestamptz,
    uploaded_by       uuid references app_user(id),
    -- Photos queue separately and upload when a connection allows; nothing
    -- blocks a record on them (§5.4).
    sync_state        text not null default 'pending'
        constraint attachment_sync_state_valid check (sync_state in ('pending','uploading','stored','failed')),

    created_at        timestamptz not null default now(),
    created_by        uuid,
    updated_at        timestamptz not null default now(),
    updated_by        uuid,
    deleted_at        timestamptz,
    row_version       integer not null default 1
);

comment on table attachment is
    'Every photo, signature and document in the system, attached to whatever it belongs to. Uploads are asynchronous by design.';

create index attachment_entity_idx on attachment (entity_type, entity_id) where deleted_at is null;
create index attachment_pending_idx on attachment (business_id, sync_state) where sync_state <> 'stored' and deleted_at is null;
select app.attach_standard_triggers('attachment');
