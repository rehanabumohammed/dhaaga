-- 0003 · Tenancy, identity, audit
--
-- Cluster 2.1 of the blueprint. Establishes the spine every later cluster hangs
-- from: the business, its branches, the people who work in it, what they are
-- allowed to do, the devices they work from, the document numbers they consume,
-- and the audit table that records what they did.
--
-- Conventions (ADR-0004): every table carries id / business_id / created_at /
-- created_by / updated_at / updated_by / deleted_at / row_version. Columns are
-- written out in full rather than injected, so a reader sees the whole table.
-- db/tests/0001_conventions.sql fails the build if any table omits one.
--
-- Uniqueness is always partial on `deleted_at is null`: a soft-deleted branch
-- code must be reusable, or the first typo would poison a code forever.

-- ===========================================================================
-- business — the tenant root
-- ===========================================================================
create table business (
    id                        uuid primary key default gen_random_uuid(),
    -- The tenant key on the tenant itself. Generated from id so that the single
    -- row-level-security predicate (business_id = current business) applies to
    -- this table with no special case (AP-7).
    business_id               uuid generated always as (id) stored,

    legal_name                text not null,
    trade_name                text,
    gstin                     text,
    pan                       text,
    address_line1             text,
    address_line2             text,
    city                      text,
    state_code                text,
    postal_code               text,
    country_code              text not null default 'IN',

    -- Localisation is architectural from P0 (decision 3). The default locale is
    -- business-wide; each user may override it.
    default_locale            text not null default 'en-IN',
    currency_code             text not null default 'INR',
    -- India's financial year starts in April. Configurable because the rule is
    -- jurisdictional, not universal.
    financial_year_start_month smallint not null default 4
        constraint business_fy_month_valid check (financial_year_start_month between 1 and 12),

    status                    text not null default 'active'
        constraint business_status_valid check (status in ('active','suspended','closed')),

    created_at                timestamptz not null default now(),
    created_by                uuid,
    updated_at                timestamptz not null default now(),
    updated_by                uuid,
    deleted_at                timestamptz,
    row_version               integer not null default 1
);

comment on table business is 'The tenant root. Exactly one row in V1; the schema is multi-tenant from day one (AP-7).';
comment on column business.business_id is 'Mirror of id so every table, including this one, carries the tenant key.';
comment on column business.financial_year_start_month is 'Configurable: 4 = April, the Indian financial year.';

select app.attach_standard_triggers('business');

-- ===========================================================================
-- branch — the unit of cash, stock, capacity and profit
-- ===========================================================================
create table branch (
    id                uuid primary key default gen_random_uuid(),
    business_id       uuid not null references business(id),

    code              text not null,
    name              text not null,
    -- Per-branch GSTIN from day one (decision 2), even though V1 runs one
    -- branch: place-of-supply and document series depend on it, and retrofitting
    -- it would mean reissuing invoices.
    gstin             text,
    state_code        text,
    address_line1     text,
    address_line2     text,
    city              text,
    postal_code       text,
    phone_e164        text,
    timezone          text not null default 'Asia/Kolkata',
    opened_on         date,
    is_active         boolean not null default true,

    created_at        timestamptz not null default now(),
    created_by        uuid,
    updated_at        timestamptz not null default now(),
    updated_by        uuid,
    deleted_at        timestamptz,
    row_version       integer not null default 1,

    constraint branch_code_unique_per_business unique nulls not distinct (business_id, code, deleted_at)
);

comment on table branch is 'An outlet. Owns cash, stock, capacity, document series and its own profit and loss.';
comment on column branch.gstin is 'Per-branch tax registration. Null while the business bills under one GSTIN.';

create index branch_business_idx on branch (business_id) where deleted_at is null;
select app.attach_standard_triggers('branch');

-- ===========================================================================
-- app_user — one login per person
-- ===========================================================================
create table app_user (
    id                uuid primary key default gen_random_uuid(),
    business_id       uuid not null references business(id),

    full_name         text not null,
    display_name      text,
    phone_e164        text,
    email             text,
    employee_code     text,
    -- Per-user locale overrides the business default (decision 3).
    locale            text,

    -- PIN fast-switching on a shared counter device (WP-7). The hash is written
    -- by a security-definer function; no client ever reads this column.
    pin_hash          text,
    pin_set_at        timestamptz,

    status            text not null default 'active'
        constraint app_user_status_valid check (status in ('invited','active','suspended','archived')),
    last_seen_at      timestamptz,

    created_at        timestamptz not null default now(),
    created_by        uuid,
    updated_at        timestamptz not null default now(),
    updated_by        uuid,
    deleted_at        timestamptz,
    row_version       integer not null default 1
);

comment on table app_user is 'A person who logs in. id matches the Supabase auth user id. Branch access is granted separately via user_branch_role.';
comment on column app_user.pin_hash is 'PIN for fast switching on a shared device. Written by a security-definer function; never selected by a client.';

-- Partial unique indexes, not UNIQUE NULLS NOT DISTINCT. The distinction is
-- load-bearing: with NULLS NOT DISTINCT two people who have no phone number
-- collide with each other, and this architecture explicitly expects tailors
-- without phones. Standard null semantics on the business columns, with the
-- soft-delete predicate in the WHERE clause, is the correct shape.
create unique index app_user_phone_unique_per_business on app_user (business_id, phone_e164)
    where deleted_at is null;
create unique index app_user_employee_code_unique_per_business on app_user (business_id, employee_code)
    where deleted_at is null;

create index app_user_business_idx on app_user (business_id) where deleted_at is null;
select app.attach_standard_triggers('app_user');

-- ===========================================================================
-- permission and role
-- ===========================================================================
-- Permissions are the application's fixed vocabulary, but they are still stored
-- per business rather than in a global table. A global table would be the one
-- exception to "every row carries business_id", and that exception is exactly
-- what makes a later multi-tenant migration painful (AP-7, ADR-0004).
create table permission (
    id                uuid primary key default gen_random_uuid(),
    business_id       uuid not null references business(id),

    code              text not null,
    domain            text not null,
    description       text,
    -- Marks a permission that lets its holder see accounting concepts. The shop
    -- surface must not expose any of these (BR-23, AP-2).
    is_books_surface  boolean not null default false,

    created_at        timestamptz not null default now(),
    created_by        uuid,
    updated_at        timestamptz not null default now(),
    updated_by        uuid,
    deleted_at        timestamptz,
    row_version       integer not null default 1,

    constraint permission_code_unique_per_business unique nulls not distinct (business_id, code, deleted_at)
);

comment on table permission is 'The permission vocabulary, seeded per business. is_books_surface marks the accounting boundary of AP-2.';
select app.attach_standard_triggers('permission');

create table role (
    id                uuid primary key default gen_random_uuid(),
    business_id       uuid not null references business(id),

    code              text not null,
    name              text not null,
    description       text,
    -- System roles are seeded and may not be deleted, but their permission set
    -- is editable by the owner (AP-1).
    is_system         boolean not null default false,
    sort_order        integer not null default 100,

    created_at        timestamptz not null default now(),
    created_by        uuid,
    updated_at        timestamptz not null default now(),
    updated_by        uuid,
    deleted_at        timestamptz,
    row_version       integer not null default 1,

    constraint role_code_unique_per_business unique nulls not distinct (business_id, code, deleted_at)
);

comment on table role is 'A named permission set. Seeded per business; the owner may adjust which permissions each role holds.';
select app.attach_standard_triggers('role');

create table role_permission (
    id                uuid primary key default gen_random_uuid(),
    business_id       uuid not null references business(id),

    role_id           uuid not null references role(id),
    permission_id     uuid not null references permission(id),

    created_at        timestamptz not null default now(),
    created_by        uuid,
    updated_at        timestamptz not null default now(),
    updated_by        uuid,
    deleted_at        timestamptz,
    row_version       integer not null default 1,

    constraint role_permission_unique unique nulls not distinct (role_id, permission_id, deleted_at)
);

comment on table role_permission is 'Which permissions a role holds. Editable by the owner: roles are seeded, their contents are configuration (AP-1).';

create index role_permission_role_idx on role_permission (role_id) where deleted_at is null;
select app.attach_standard_triggers('role_permission');

-- ===========================================================================
-- user_branch_role — access is granted per branch, not per person
-- ===========================================================================
create table user_branch_role (
    id                uuid primary key default gen_random_uuid(),
    business_id       uuid not null references business(id),

    user_id           uuid not null references app_user(id),
    branch_id         uuid not null references branch(id),
    role_id           uuid not null references role(id),

    granted_at        timestamptz not null default now(),
    granted_by        uuid,
    revoked_at        timestamptz,
    revoked_by        uuid,
    revoke_reason     text,

    created_at        timestamptz not null default now(),
    created_by        uuid,
    updated_at        timestamptz not null default now(),
    updated_by        uuid,
    deleted_at        timestamptz,
    row_version       integer not null default 1,

    constraint user_branch_role_unique unique nulls not distinct (user_id, branch_id, role_id, deleted_at)
);

comment on table user_branch_role is 'One row per (person, branch, role). A manager covering two outlets has two rows and one login.';
comment on column user_branch_role.revoked_at is 'Revocation is recorded, not deleted: who lost access and when is a security question.';

create index user_branch_role_user_idx on user_branch_role (user_id) where deleted_at is null and revoked_at is null;
create index user_branch_role_branch_idx on user_branch_role (branch_id) where deleted_at is null and revoked_at is null;
select app.attach_standard_triggers('user_branch_role');

-- ===========================================================================
-- device — offline attribution
-- ===========================================================================
create table device (
    id                uuid primary key default gen_random_uuid(),
    business_id       uuid not null references business(id),

    label             text,
    platform          text
        constraint device_platform_valid check (platform in ('android','ios','web','windows','other')),
    model             text,
    app_version       text,
    last_user_id      uuid references app_user(id),
    home_branch_id    uuid references branch(id),

    first_seen_at     timestamptz not null default now(),
    last_seen_at      timestamptz,
    last_sync_at      timestamptz,
    -- Offline volume per device is reported (§5.4): an environment with weaker
    -- controls should be observable, not merely tolerated.
    offline_minutes_total bigint not null default 0,
    is_active         boolean not null default true,

    created_at        timestamptz not null default now(),
    created_by        uuid,
    updated_at        timestamptz not null default now(),
    updated_by        uuid,
    deleted_at        timestamptz,
    row_version       integer not null default 1
);

comment on table device is 'A registered client device. Every offline action is attributed to one (§5.4).';
create index device_business_idx on device (business_id) where deleted_at is null;
select app.attach_standard_triggers('device');

-- ===========================================================================
-- number_series, number_lease, number_void — BR-14
-- ===========================================================================
create table number_series (
    id                uuid primary key default gen_random_uuid(),
    business_id       uuid not null references business(id),
    branch_id         uuid not null references branch(id),

    doc_type          text not null
        constraint number_series_doc_type_valid check (doc_type in (
            'order_token','job_card','tax_invoice','bill_of_supply',
            'credit_note','delivery_note','estimate','payment_receipt',
            'purchase_bill','stock_transfer','wage_payout')),
    financial_year    text not null,
    prefix            text not null default '',
    suffix            text not null default '',
    padding           smallint not null default 5
        constraint number_series_padding_valid check (padding between 1 and 12),
    next_value        integer not null default 1
        constraint number_series_next_positive check (next_value >= 1),
    -- Only series that may be allocated offline are leasable. The tax invoice
    -- series is deliberately not: its register should contain no unexplained
    -- holes, so it is issued server-side (§5.3).
    is_offline_leasable boolean not null default false,

    created_at        timestamptz not null default now(),
    created_by        uuid,
    updated_at        timestamptz not null default now(),
    updated_by        uuid,
    deleted_at        timestamptz,
    row_version       integer not null default 1,

    constraint number_series_unique unique nulls not distinct (branch_id, doc_type, financial_year, deleted_at)
);

comment on table number_series is 'One counter per branch, document type and financial year (BR-14).';
comment on column number_series.is_offline_leasable is 'Order tokens are leased to devices; tax invoice numbers are never (§5.3).';
select app.attach_standard_triggers('number_series');

create table number_lease (
    id                uuid primary key default gen_random_uuid(),
    business_id       uuid not null references business(id),
    branch_id         uuid not null references branch(id),

    series_id         uuid not null references number_series(id),
    device_id         uuid not null references device(id),

    range_start       integer not null,
    range_end         integer not null,
    next_value        integer not null,
    issued_at         timestamptz not null default now(),
    expires_at        timestamptz not null,
    status            text not null default 'active'
        constraint number_lease_status_valid check (status in ('active','exhausted','expired','returned')),
    closed_at         timestamptz,

    created_at        timestamptz not null default now(),
    created_by        uuid,
    updated_at        timestamptz not null default now(),
    updated_by        uuid,
    deleted_at        timestamptz,
    row_version       integer not null default 1,

    constraint number_lease_range_valid check (range_end >= range_start),
    constraint number_lease_next_in_range check (next_value between range_start and range_end + 1)
);

comment on table number_lease is 'A block of numbers handed to a device so an offline token prints its final number (§5.3).';

-- Two devices must never hold overlapping numbers from the same series. An
-- exclusion constraint enforces this at the database, not in application logic.
create extension if not exists btree_gist;
alter table number_lease
    add constraint number_lease_no_overlap
    exclude using gist (
        series_id with =,
        int4range(range_start, range_end, '[]') with &&
    ) where (deleted_at is null);

create index number_lease_device_idx on number_lease (device_id) where status = 'active' and deleted_at is null;
select app.attach_standard_triggers('number_lease');

create table number_void (
    id                uuid primary key default gen_random_uuid(),
    business_id       uuid not null references business(id),
    branch_id         uuid not null references branch(id),

    series_id         uuid not null references number_series(id),
    lease_id          uuid references number_lease(id),
    value             integer not null,
    reason_code       text not null,
    reason_text       text,
    voided_at         timestamptz not null default now(),
    voided_by         uuid,

    created_at        timestamptz not null default now(),
    created_by        uuid,
    updated_at        timestamptz not null default now(),
    updated_by        uuid,
    deleted_at        timestamptz,
    row_version       integer not null default 1,

    constraint number_void_unique unique nulls not distinct (series_id, value, deleted_at)
);

comment on table number_void is
    'Every number issued but never used, with a reason. This is what makes each gap in a register explainable (BR-14).';
select app.attach_standard_triggers('number_void');

-- ===========================================================================
-- audit_event — the table. Triggers that fill it arrive in WP-4.
-- ===========================================================================
create table audit_event (
    id                uuid primary key default gen_random_uuid(),
    business_id       uuid not null references business(id),
    branch_id         uuid references branch(id),

    entity_type       text not null,
    entity_id         uuid,
    action            text not null
        constraint audit_event_action_valid check (action in ('insert','update','delete','login','logout','grant','revoke','export','other')),

    before_data       jsonb,
    after_data        jsonb,
    changed_fields    text[],

    reason_code       text,
    reason_text       text,

    actor_user_id     uuid references app_user(id),
    device_id         uuid references device(id),
    source            text not null default 'app'
        constraint audit_event_source_valid check (source in ('app','web','system','migration','console')),
    -- Both clocks are kept (§5.5): a device with a wrong clock must not be able
    -- to backdate an action.
    occurred_at       timestamptz not null default now(),
    recorded_at       timestamptz not null default now(),

    created_at        timestamptz not null default now(),
    created_by        uuid,
    updated_at        timestamptz not null default now(),
    updated_by        uuid,
    deleted_at        timestamptz,
    row_version       integer not null default 1
);

comment on table audit_event is
    'Append-only record of who changed what, when, from where (BR-13). Grants are restricted to INSERT in WP-4; the triggers that populate it arrive there too.';
comment on column audit_event.occurred_at is 'When the actor performed it (may be offline). recorded_at is when the server received it.';

create index audit_event_entity_idx on audit_event (entity_type, entity_id, occurred_at desc);
create index audit_event_actor_idx on audit_event (actor_user_id, occurred_at desc);
create index audit_event_business_time_idx on audit_event (business_id, occurred_at desc);
select app.attach_standard_triggers('audit_event');
