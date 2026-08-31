-- 0006 · Orders, garments, production and capacity
--
-- Cluster 2.4 of the blueprint. The commercial structure and the production
-- structure are deliberately different shapes joined at the garment (§6):
--
--   sales_order -> order_item -> garment -> job_card -> production_task
--                                   |
--                                   +-> trial, alteration, delivery_line
--
-- Quantity creates rows (BR-07): three shirts on one priced line are three
-- garment records, each with its own number, stage, tailor, promised date and
-- allocated amount. That is what makes partial delivery exact rather than
-- approximate.
--
-- Order totals are deliberately NOT stored on sales_order. Every figure is
-- derived from the priced lines and the allocations beneath them (AP-8); a
-- maintained total is a number that can drift from the rows it claims to
-- summarise. The reporting views arrive with the finance cluster.

-- ===========================================================================
-- Production configuration — stages are owner-configurable (AP-1)
-- ===========================================================================
create table workflow_template (
    id                uuid primary key default gen_random_uuid(),
    business_id       uuid not null references business(id),

    garment_type_id   uuid not null references garment_type(id),
    version           integer not null default 1,
    is_current        boolean not null default true,
    note              text,

    created_at        timestamptz not null default now(),
    created_by        uuid,
    updated_at        timestamptz not null default now(),
    updated_by        uuid,
    deleted_at        timestamptz,
    row_version       integer not null default 1,

    constraint workflow_template_version_unique unique nulls not distinct (garment_type_id, version, deleted_at)
);

comment on table workflow_template is
    'The production route for a garment type. A blouse skips what a blazer needs, and adding embroidery as an outsourced stage is configuration, not code.';

create unique index workflow_template_one_current on workflow_template (garment_type_id)
    where is_current and deleted_at is null;
select app.attach_standard_triggers('workflow_template');

create table workflow_stage (
    id                  uuid primary key default gen_random_uuid(),
    business_id         uuid not null references business(id),

    template_id         uuid not null references workflow_template(id),
    code                text not null,
    label               text not null,
    sequence_no         integer not null,
    -- The currency of the capacity engine (§6). Seeded from the owner's
    -- estimates and corrected from actual task durations over time.
    standard_minutes    integer not null default 0
        constraint workflow_stage_minutes_non_negative check (standard_minutes >= 0),
    -- Buffer between this stage finishing and the next being able to start.
    buffer_minutes      integer not null default 0,
    is_outsourced       boolean not null default false,
    -- Whether completing this stage earns piece-rate wages (BR-16).
    is_wage_bearing     boolean not null default true,
    requires_qc         boolean not null default false,

    created_at          timestamptz not null default now(),
    created_by          uuid,
    updated_at          timestamptz not null default now(),
    updated_by          uuid,
    deleted_at          timestamptz,
    row_version         integer not null default 1,

    constraint workflow_stage_code_unique unique nulls not distinct (template_id, code, deleted_at),
    constraint workflow_stage_sequence_unique unique nulls not distinct (template_id, sequence_no, deleted_at)
);

comment on table workflow_stage is
    'One step of a production route, with the standard minutes the capacity engine schedules against.';
select app.attach_standard_triggers('workflow_stage');

create table priority_class (
    id                uuid primary key default gen_random_uuid(),
    business_id       uuid not null references business(id),

    code              text not null,
    label             text not null,
    -- Higher weight pre-empts. The screen shows which existing dates an urgent
    -- insert pushes, rather than silently moving them (§6).
    queue_weight      integer not null default 100,
    sort_order        integer not null default 100,
    is_default        boolean not null default false,
    is_active         boolean not null default true,

    created_at        timestamptz not null default now(),
    created_by        uuid,
    updated_at        timestamptz not null default now(),
    updated_by        uuid,
    deleted_at        timestamptz,
    row_version       integer not null default 1,

    constraint priority_class_code_unique unique nulls not distinct (business_id, code, deleted_at)
);

comment on table priority_class is 'Normal, urgent, VIP - owner-defined, with the weight each carries in the queue.';
create unique index priority_class_one_default on priority_class (business_id) where is_default and deleted_at is null;
select app.attach_standard_triggers('priority_class');

-- ===========================================================================
-- Capacity inputs (§6)
-- ===========================================================================
create table branch_calendar (
    id                uuid primary key default gen_random_uuid(),
    business_id       uuid not null references business(id),
    branch_id         uuid not null references branch(id),

    weekday           smallint not null
        constraint branch_calendar_weekday_valid check (weekday between 0 and 6),
    is_working        boolean not null default true,
    opens_at          time,
    closes_at         time,

    created_at        timestamptz not null default now(),
    created_by        uuid,
    updated_at        timestamptz not null default now(),
    updated_by        uuid,
    deleted_at        timestamptz,
    row_version       integer not null default 1,

    constraint branch_calendar_unique unique nulls not distinct (branch_id, weekday, deleted_at),
    constraint branch_calendar_hours_sane check (opens_at is null or closes_at is null or closes_at > opens_at)
);

comment on table branch_calendar is 'The normal working week for a branch. Non-working time is skipped when a promise date is calculated.';
select app.attach_standard_triggers('branch_calendar');

create table calendar_exception (
    id                uuid primary key default gen_random_uuid(),
    business_id       uuid not null references business(id),
    branch_id         uuid not null references branch(id),

    exception_date    date not null,
    is_working        boolean not null default false,
    opens_at          time,
    closes_at         time,
    reason            text,

    created_at        timestamptz not null default now(),
    created_by        uuid,
    updated_at        timestamptz not null default now(),
    updated_by        uuid,
    deleted_at        timestamptz,
    row_version       integer not null default 1,

    constraint calendar_exception_unique unique nulls not distinct (branch_id, exception_date, deleted_at)
);

comment on table calendar_exception is 'Festival closures, half-days and the occasional extra working Sunday.';
select app.attach_standard_triggers('calendar_exception');

create table staff_capacity (
    id                uuid primary key default gen_random_uuid(),
    business_id       uuid not null references business(id),
    branch_id         uuid not null references branch(id),

    user_id           uuid not null references app_user(id),
    minutes_per_day   integer not null
        constraint staff_capacity_minutes_positive check (minutes_per_day > 0),
    -- Multiplier on standard minutes. A fast finisher and a careful beginner
    -- both produce honest dates once this is calibrated from actuals.
    efficiency_factor numeric(4,2) not null default 1.00
        constraint staff_capacity_efficiency_sane check (efficiency_factor > 0 and efficiency_factor <= 3),
    effective_from    date not null,
    effective_to      date,

    created_at        timestamptz not null default now(),
    created_by        uuid,
    updated_at        timestamptz not null default now(),
    updated_by        uuid,
    deleted_at        timestamptz,
    row_version       integer not null default 1,

    constraint staff_capacity_range_valid check (effective_to is null or effective_to > effective_from)
);

comment on table staff_capacity is 'How many minutes a person actually has in a day, and how fast they work relative to standard.';

-- One capacity record per person per branch at any moment, or the pool of
-- available minutes is ambiguous and every promise date built on it is guesswork.
alter table staff_capacity
    add constraint staff_capacity_no_overlap
    exclude using gist (
        user_id with =,
        branch_id with =,
        daterange(effective_from, effective_to) with &&
    ) where (deleted_at is null);

select app.attach_standard_triggers('staff_capacity');

create table staff_skill (
    id                uuid primary key default gen_random_uuid(),
    business_id       uuid not null references business(id),

    user_id           uuid not null references app_user(id),
    garment_type_id   uuid not null references garment_type(id),
    skill_level       smallint not null default 3
        constraint staff_skill_level_valid check (skill_level between 1 and 5),
    is_eligible       boolean not null default true,

    created_at        timestamptz not null default now(),
    created_by        uuid,
    updated_at        timestamptz not null default now(),
    updated_by        uuid,
    deleted_at        timestamptz,
    row_version       integer not null default 1,

    constraint staff_skill_unique unique nulls not distinct (user_id, garment_type_id, deleted_at)
);

comment on table staff_skill is
    'Who may be scheduled for what. Work is never scheduled into a pool that cannot do it - a blouse does not go to a pool rated only for trousers.';
select app.attach_standard_triggers('staff_skill');

-- ===========================================================================
-- sales_order — the commercial agreement
-- ===========================================================================
create table sales_order (
    id                    uuid primary key default gen_random_uuid(),
    business_id           uuid not null references business(id),
    branch_id             uuid not null references branch(id),

    order_no              text not null,
    customer_id           uuid not null references customer(id),
    -- The father settling for the whole family: the bill groups at the
    -- household while each garment still belongs to the person it was cut for.
    bill_to_household_id  uuid references household(id),

    order_date            date not null default current_date,
    priority_class_id     uuid references priority_class(id),
    source                text not null default 'walk_in'
        constraint sales_order_source_valid check (source in ('walk_in','phone','whatsapp','online','other')),
    price_list_id         uuid references price_list(id),
    -- Whether the balance for delivered pieces must be cleared at handover, or
    -- at completion. A business setting, overridable per order with a reason.
    collection_policy     text not null default 'on_delivery'
        constraint sales_order_collection_policy_valid check (collection_policy in ('on_delivery','on_completion')),

    lifecycle             text not null default 'draft'
        constraint sales_order_lifecycle_valid check (lifecycle in ('draft','confirmed','cancelled')),
    confirmed_at          timestamptz,
    cancelled_at          timestamptz,
    cancel_reason_code    text,
    cancel_reason_text    text,
    notes                 text,

    created_at            timestamptz not null default now(),
    created_by            uuid,
    updated_at            timestamptz not null default now(),
    updated_by            uuid,
    deleted_at            timestamptz,
    row_version           integer not null default 1,

    constraint sales_order_no_unique unique nulls not distinct (branch_id, order_no, deleted_at),
    constraint sales_order_cancel_coherent check (
        (lifecycle = 'cancelled' and cancelled_at is not null) or lifecycle <> 'cancelled'
    ),
    constraint sales_order_confirm_coherent check (
        (lifecycle = 'draft' and confirmed_at is null) or lifecycle <> 'draft'
    )
);

comment on table sales_order is
    'The commercial agreement. Its delivery status is derived from its garments, never set by hand (BR-06); its totals are derived from its lines (AP-8).';
comment on column sales_order.lifecycle is
    'Only draft, confirmed or cancelled. "Partially delivered" is a computed fact about the garments, not a state stored here.';

create index sales_order_branch_date_idx on sales_order (branch_id, order_date desc) where deleted_at is null;
create index sales_order_customer_idx on sales_order (customer_id) where deleted_at is null;
select app.attach_standard_triggers('sales_order');

create table order_item (
    id                uuid primary key default gen_random_uuid(),
    business_id       uuid not null references business(id),
    branch_id         uuid not null references branch(id),

    order_id          uuid not null references sales_order(id),
    garment_type_id   uuid not null references garment_type(id),
    quantity          integer not null
        constraint order_item_quantity_positive check (quantity >= 1),
    unit_price        app.money_amount not null
        constraint order_item_price_non_negative check (unit_price >= 0),
    -- Recorded as its own figure, never folded into a reduced price, so
    -- discount leakage stays measurable (BR-20).
    discount_amount   app.money_amount not null default 0
        constraint order_item_discount_non_negative check (discount_amount >= 0),
    discount_reason_code text,
    tax_code_id       uuid references tax_code(id),
    line_no           integer not null default 1,
    notes             text,

    created_at        timestamptz not null default now(),
    created_by        uuid,
    updated_at        timestamptz not null default now(),
    updated_by        uuid,
    deleted_at        timestamptz,
    row_version       integer not null default 1,

    constraint order_item_discount_within_line check (discount_amount <= unit_price * quantity)
);

comment on table order_item is
    'A priced line. Quantity here becomes that many garment rows (BR-07): the line is commercial, the garment is physical.';

create index order_item_order_idx on order_item (order_id) where deleted_at is null;
select app.attach_standard_triggers('order_item');

-- ===========================================================================
-- garment — the unit of production
-- ===========================================================================
create table garment (
    id                      uuid primary key default gen_random_uuid(),
    business_id             uuid not null references business(id),
    branch_id               uuid not null references branch(id),

    order_item_id           uuid not null references order_item(id),
    garment_no              text not null,
    piece_no                integer not null default 1,

    -- This garment's share of its line, net of discount. A decision, not a
    -- derivation: the rounding remainder falls on the last piece so the pieces
    -- always sum exactly to the line (§4).
    allocated_amount        app.money_amount not null default 0,
    allocated_tax_amount    app.money_amount not null default 0,

    measurement_snapshot_id uuid references measurement_snapshot(id),

    -- Customer cloth and shop cloth are different objects with different
    -- consequences (BR-05). Which one this garment uses is recorded here; the
    -- material itself lives in the inventory cluster.
    fabric_source           text not null default 'customer'
        constraint garment_fabric_source_valid check (fabric_source in ('customer','shop','mixed')),

    -- The invariant lifecycle. Production stages are configurable
    -- (current_stage_id); this is not.
    lifecycle               text not null default 'pending'
        constraint garment_lifecycle_valid check (lifecycle in
            ('pending','in_production','ready','delivered','cancelled')),
    current_stage_id        uuid references workflow_stage(id),

    -- Both dates are kept for the life of the garment. On-time performance is
    -- always measured against the original promise (BR-11), so revising a date
    -- can never improve the score.
    promised_date_original  date,
    promised_date_current   date,
    trial_required          boolean not null default false,

    ready_at                timestamptz,
    delivered_at            timestamptz,
    cancelled_at            timestamptz,
    cancel_reason_code      text,
    notes                   text,

    created_at              timestamptz not null default now(),
    created_by              uuid,
    updated_at              timestamptz not null default now(),
    updated_by              uuid,
    deleted_at              timestamptz,
    row_version             integer not null default 1,

    constraint garment_no_unique unique nulls not distinct (business_id, garment_no, deleted_at),
    constraint garment_allocation_non_negative check (allocated_amount >= 0 and allocated_tax_amount >= 0),
    constraint garment_delivered_coherent check (
        (lifecycle = 'delivered' and delivered_at is not null) or lifecycle <> 'delivered'
    ),
    constraint garment_cancelled_coherent check (
        (lifecycle = 'cancelled' and cancelled_at is not null) or lifecycle <> 'cancelled'
    )
);

comment on table garment is
    'One physical piece. Everything on the shop floor - assignment, capacity, wages, delivery - is counted here, not on the order.';
comment on column garment.allocated_amount is
    'Share of the line net of discount. Rounding remainder falls on the last piece so pieces sum exactly to the line.';
comment on column garment.promised_date_original is
    'The date promised at confirmation. Never updated - BR-11 depends on it.';

create index garment_order_item_idx on garment (order_item_id) where deleted_at is null;
create index garment_branch_lifecycle_idx on garment (branch_id, lifecycle) where deleted_at is null;
create index garment_due_idx on garment (branch_id, promised_date_current)
    where lifecycle in ('pending','in_production') and deleted_at is null;
select app.attach_standard_triggers('garment');

-- The snapshot's link to its garment, deferred from 0005 because garment did
-- not exist yet. The column lives with the measurement story; the constraint
-- belongs here.
alter table measurement_snapshot
    add constraint measurement_snapshot_garment_fk
    foreign key (garment_id) references garment(id);

create table garment_style_option (
    id                uuid primary key default gen_random_uuid(),
    business_id       uuid not null references business(id),

    garment_id        uuid not null references garment(id),
    group_id          uuid not null references style_option_group(id),
    option_id         uuid not null references style_option(id),
    -- Frozen at confirmation like the measurements: repricing a style later
    -- must not change what an existing garment cost or how long it was planned
    -- to take.
    price_delta_applied app.money_amount not null default 0,
    extra_minutes_applied integer not null default 0,

    created_at        timestamptz not null default now(),
    created_by        uuid,
    updated_at        timestamptz not null default now(),
    updated_by        uuid,
    deleted_at        timestamptz,
    row_version       integer not null default 1,

    constraint garment_style_option_unique unique nulls not distinct (garment_id, option_id, deleted_at)
);

comment on table garment_style_option is
    'The style choices for one garment, with the price and time they carried when the order was confirmed.';
select app.attach_standard_triggers('garment_style_option');

-- ===========================================================================
-- job_card and production_task
-- ===========================================================================
create table job_card (
    id                uuid primary key default gen_random_uuid(),
    business_id       uuid not null references business(id),
    branch_id         uuid not null references branch(id),

    job_no            text not null,
    assigned_to       uuid references app_user(id),
    kind              text not null default 'production'
        constraint job_card_kind_valid check (kind in ('production','rework')),
    issued_at         timestamptz,
    due_at            timestamptz,
    returned_at       timestamptz,
    status            text not null default 'open'
        constraint job_card_status_valid check (status in ('open','issued','in_progress','returned','closed','cancelled')),
    notes             text,

    created_at        timestamptz not null default now(),
    created_by        uuid,
    updated_at        timestamptz not null default now(),
    updated_by        uuid,
    deleted_at        timestamptz,
    row_version       integer not null default 1,

    constraint job_card_no_unique unique nulls not distinct (business_id, job_no, deleted_at)
);

comment on table job_card is
    'A work order for one tailor, batching one or more garments. Printed with a QR code so a manager can move stages for a tailor who does not use a phone.';
select app.attach_standard_triggers('job_card');

create table job_card_garment (
    id                uuid primary key default gen_random_uuid(),
    business_id       uuid not null references business(id),

    job_card_id       uuid not null references job_card(id),
    garment_id        uuid not null references garment(id),
    is_active         boolean not null default true,
    removed_at        timestamptz,

    created_at        timestamptz not null default now(),
    created_by        uuid,
    updated_at        timestamptz not null default now(),
    updated_by        uuid,
    deleted_at        timestamptz,
    row_version       integer not null default 1,

    constraint job_card_garment_unique unique nulls not distinct (job_card_id, garment_id, deleted_at)
);

comment on table job_card_garment is
    'Which garments a job card carries. A link table rather than a column on garment, because a garment returning for rework joins a second job card and the history of both must survive.';

-- A garment is on at most one active job card at a time.
create unique index job_card_garment_one_active on job_card_garment (garment_id)
    where is_active and deleted_at is null;
select app.attach_standard_triggers('job_card_garment');

create table production_task (
    id                uuid primary key default gen_random_uuid(),
    business_id       uuid not null references business(id),
    branch_id         uuid not null references branch(id),

    job_card_id       uuid not null references job_card(id),
    garment_id        uuid not null references garment(id),
    stage_id          uuid not null references workflow_stage(id),
    sequence_no       integer not null,
    assignee_id       uuid references app_user(id),

    standard_minutes  integer not null default 0
        constraint production_task_minutes_non_negative check (standard_minutes >= 0),
    planned_start     timestamptz,
    planned_end       timestamptz,
    actual_start      timestamptz,
    actual_end        timestamptz,

    status            text not null default 'pending'
        constraint production_task_status_valid check (status in ('pending','in_progress','done','skipped','cancelled')),
    -- The rate this task earns on completion (BR-16). Frozen when the task is
    -- created so a later rate change does not silently restate past wages.
    piece_rate        app.money_amount not null default 0
        constraint production_task_rate_non_negative check (piece_rate >= 0),
    notes             text,

    created_at        timestamptz not null default now(),
    created_by        uuid,
    updated_at        timestamptz not null default now(),
    updated_by        uuid,
    deleted_at        timestamptz,
    row_version       integer not null default 1,

    constraint production_task_actual_order check (actual_end is null or actual_start is null or actual_end >= actual_start),
    constraint production_task_planned_order check (planned_end is null or planned_start is null or planned_end >= planned_start),
    constraint production_task_done_has_end check (status <> 'done' or actual_end is not null),
    constraint production_task_unique_stage unique nulls not distinct (garment_id, job_card_id, stage_id, deleted_at)
);

comment on table production_task is
    'One stage of one garment on one job card. The row that feeds capacity, wages, bottleneck reporting and actual-versus-standard calibration.';

create index production_task_assignee_idx on production_task (assignee_id, status) where deleted_at is null;
create index production_task_garment_idx on production_task (garment_id) where deleted_at is null;
create index production_task_queue_idx on production_task (branch_id, status, planned_start) where deleted_at is null;
select app.attach_standard_triggers('production_task');

-- ===========================================================================
-- Trial, alteration, date override
-- ===========================================================================
create table trial_event (
    id                uuid primary key default gen_random_uuid(),
    business_id       uuid not null references business(id),
    branch_id         uuid not null references branch(id),

    garment_id        uuid not null references garment(id),
    attempt_no        integer not null default 1,
    scheduled_at      timestamptz,
    occurred_at       timestamptz,
    outcome           text
        constraint trial_event_outcome_valid check (outcome in ('fits','alterations_noted','customer_absent','rescheduled')),
    notes             text,

    created_at        timestamptz not null default now(),
    created_by        uuid,
    updated_at        timestamptz not null default now(),
    updated_by        uuid,
    deleted_at        timestamptz,
    row_version       integer not null default 1,

    constraint trial_event_unique unique nulls not distinct (garment_id, attempt_no, deleted_at)
);

comment on table trial_event is 'A fitting. Repeatable: a garment may go to trial more than once, and each attempt is kept.';
select app.attach_standard_triggers('trial_event');

create table alteration (
    id                    uuid primary key default gen_random_uuid(),
    business_id           uuid not null references business(id),
    branch_id             uuid not null references branch(id),

    garment_id            uuid not null references garment(id),
    source_job_card_id    uuid references job_card(id),
    rework_job_card_id    uuid references job_card(id),

    reason_code           text not null,
    reason_text           text,
    -- Only shop-fault rework is a quality defect. Customer-preference changes
    -- are counted separately, or the rework rate measures the wrong thing.
    fault_party           text not null
        constraint alteration_fault_party_valid check (fault_party in ('shop','customer_preference','fabric','unknown')),
    chargeable            boolean not null default false,
    charge_amount         app.money_amount not null default 0
        constraint alteration_charge_non_negative check (charge_amount >= 0),
    due_date              date,
    status                text not null default 'open'
        constraint alteration_status_valid check (status in ('open','in_progress','done','cancelled')),
    completed_at          timestamptz,

    created_at            timestamptz not null default now(),
    created_by            uuid,
    updated_at            timestamptz not null default now(),
    updated_by            uuid,
    deleted_at            timestamptz,
    row_version           integer not null default 1,

    -- A free alteration cannot carry a charge, and a chargeable one must say
    -- how much. Ambiguity here becomes an argument at the counter.
    constraint alteration_charge_coherent check (
        (chargeable and charge_amount > 0) or (not chargeable and charge_amount = 0)
    )
);

comment on table alteration is
    'A rework job in its own right, not an edit to the original (BR-08). Fault party is what makes rework rate an honest quality signal.';

create index alteration_garment_idx on alteration (garment_id) where deleted_at is null;
select app.attach_standard_triggers('alteration');

create table date_override (
    id                uuid primary key default gen_random_uuid(),
    business_id       uuid not null references business(id),
    branch_id         uuid not null references branch(id),

    entity_type       text not null
        constraint date_override_entity_valid check (entity_type in ('garment','order','alteration')),
    entity_id         uuid not null,
    date_kind         text not null default 'promised_delivery'
        constraint date_override_kind_valid check (date_kind in ('promised_delivery','trial','alteration_due')),

    -- Everything BR-10 requires, all mandatory.
    original_date     date not null,
    new_date          date not null,
    user_id           uuid references app_user(id),
    reason_code       text not null,
    reason_text       text,
    approved_by       uuid references app_user(id),
    overridden_at     timestamptz not null default now(),

    created_at        timestamptz not null default now(),
    created_by        uuid,
    updated_at        timestamptz not null default now(),
    updated_by        uuid,
    deleted_at        timestamptz,
    row_version       integer not null default 1,

    constraint date_override_actually_changes check (new_date <> original_date)
);

comment on table date_override is
    'A promise date changed by a person, with what it was, what it became and why (BR-10). Override frequency is reported per user alongside their on-time rate.';

create index date_override_entity_idx on date_override (entity_type, entity_id) where deleted_at is null;
create index date_override_user_idx on date_override (user_id, overridden_at desc) where deleted_at is null;
select app.attach_standard_triggers('date_override');

-- ===========================================================================
-- Delivery — partial by design
-- ===========================================================================
create table delivery_note (
    id                    uuid primary key default gen_random_uuid(),
    business_id           uuid not null references business(id),
    branch_id             uuid not null references branch(id),

    note_no               text not null,
    order_id              uuid not null references sales_order(id),
    delivered_at          timestamptz not null default now(),
    delivered_by          uuid references app_user(id),
    received_by_name      text,
    acknowledgment_id     uuid references attachment(id),
    -- Set when goods were released with money outstanding: the override is
    -- recorded rather than prevented, and it is reported (§4).
    collection_overridden boolean not null default false,
    override_reason_code  text,
    notes                 text,

    created_at            timestamptz not null default now(),
    created_by            uuid,
    updated_at            timestamptz not null default now(),
    updated_by            uuid,
    deleted_at            timestamptz,
    row_version           integer not null default 1,

    constraint delivery_note_no_unique unique nulls not distinct (branch_id, note_no, deleted_at)
);

comment on table delivery_note is
    'One handover event. An order may have several: partial delivery is the normal case, not an exception (§4).';

create index delivery_note_order_idx on delivery_note (order_id) where deleted_at is null;
select app.attach_standard_triggers('delivery_note');

create table delivery_line (
    id                uuid primary key default gen_random_uuid(),
    business_id       uuid not null references business(id),

    delivery_note_id  uuid not null references delivery_note(id),
    garment_id        uuid not null references garment(id),
    -- A garment can go out, come back for alteration, and go out again. The
    -- direction makes that history explicit (BR-08).
    direction         text not null default 'out'
        constraint delivery_line_direction_valid check (direction in ('out','return')),
    return_reason_code text,

    created_at        timestamptz not null default now(),
    created_by        uuid,
    updated_at        timestamptz not null default now(),
    updated_by        uuid,
    deleted_at        timestamptz,
    row_version       integer not null default 1,

    constraint delivery_line_unique unique nulls not distinct (delivery_note_id, garment_id, direction, deleted_at)
);

comment on table delivery_line is
    'Which garments moved on a handover, and in which direction. The rule that a garment cannot go out twice without a return in between is a state-machine invariant enforced by the delivery service in P2, with its own tests.';

create index delivery_line_garment_idx on delivery_line (garment_id) where deleted_at is null;
select app.attach_standard_triggers('delivery_line');
