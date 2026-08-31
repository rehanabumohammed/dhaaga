-- 0008 · Inventory — two registers that must never touch
--
-- Cluster 2.6 of the blueprint, and the structural expression of BR-05.
--
-- Shop stock is an asset: it is purchased, valued, consumed, and it posts to
-- Inventory and Material cost accounts.
--
-- Customer-owned cloth is a custody obligation: it is received, issued, wasted,
-- returned, and it posts NOTHING. Not an asset, not a liability with a value.
-- The separation is structural rather than a flag: customer_material has no
-- cost column that feeds any account, stock_movement has no column capable of
-- referencing customer material, and neither customer table has a journal
-- reference. A test asserts all three.

-- ===========================================================================
-- Shop stock
-- ===========================================================================
create table stock_item (
    id                uuid primary key default gen_random_uuid(),
    business_id       uuid not null references business(id),

    code              text not null,
    name              text not null,
    kind              text not null default 'fabric'
        constraint stock_item_kind_valid check (kind in ('fabric','trim','consumable','finished_good')),
    uom               text not null default 'metre'
        constraint stock_item_uom_valid check (uom in ('metre','piece','roll','metre_square','kilogram','set')),
    -- Weighted average is the default because it is the simplest method that
    -- stays defensible under audit. FIFO is a later option, per item.
    valuation_method  text not null default 'weighted_average'
        constraint stock_item_valuation_valid check (valuation_method in ('weighted_average','fifo')),
    tax_code_id       uuid references tax_code(id),
    reorder_level     app.quantity,
    -- Offline stock issues can drive a balance negative (§5.1 tier 2). Whether
    -- that is tolerated is a per-item decision, not a global one.
    allow_negative    boolean not null default true,
    is_active         boolean not null default true,
    notes             text,

    created_at        timestamptz not null default now(),
    created_by        uuid,
    updated_at        timestamptz not null default now(),
    updated_by        uuid,
    deleted_at        timestamptz,
    row_version       integer not null default 1,

    constraint stock_item_code_unique unique nulls not distinct (business_id, code, deleted_at)
);

comment on table stock_item is
    'Something the business owns and consumes: fabric by the metre, trims by the piece. Ownership is implicit in this table - customer cloth lives in customer_material and never here.';

select app.attach_standard_triggers('stock_item');

create table stock_movement (
    id                uuid primary key default gen_random_uuid(),
    business_id       uuid not null references business(id),
    branch_id         uuid not null references branch(id),

    stock_item_id     uuid not null references stock_item(id),
    movement_type     text not null
        constraint stock_movement_type_valid check (movement_type in
            ('opening','purchase','issue','return','wastage','transfer_out','transfer_in','adjustment','sale')),
    -- Signed, so a balance is a sum and nothing has to know which types add and
    -- which subtract (BR-09).
    qty_signed        app.quantity not null
        constraint stock_movement_qty_not_zero check (qty_signed <> 0),
    unit_cost         app.money_amount not null default 0
        constraint stock_movement_cost_non_negative check (unit_cost >= 0),
    total_cost        app.money_amount not null default 0,

    -- What caused it. A movement with no cause is an unexplained change in
    -- something the owner paid for.
    ref_doc_type      text
        constraint stock_movement_ref_valid check (ref_doc_type in
            ('purchase_bill','garment','stock_transfer','invoice','count','manual')),
    ref_doc_id        uuid,
    garment_id        uuid references garment(id),
    reason_code       text,
    reason_text       text,
    occurred_at       timestamptz not null default now(),
    journal_entry_id  uuid references journal_entry(id),

    created_at        timestamptz not null default now(),
    created_by        uuid,
    updated_at        timestamptz not null default now(),
    updated_by        uuid,
    deleted_at        timestamptz,
    row_version       integer not null default 1,

    -- Adjustments and wastage are where stock quietly disappears. Both must say
    -- why, every time.
    constraint stock_movement_adjustment_needs_reason check (
        movement_type not in ('adjustment','wastage') or reason_code is not null
    )
);

comment on table stock_movement is
    'Append-only. Balances are derived from these rows; no screen edits a balance, and a correction is an adjustment movement with a reason that stays visible forever (BR-09).';

create index stock_movement_item_branch_idx on stock_movement (stock_item_id, branch_id, occurred_at);
create index stock_movement_garment_idx on stock_movement (garment_id) where deleted_at is null;
create index stock_movement_ref_idx on stock_movement (ref_doc_type, ref_doc_id) where deleted_at is null;
select app.attach_standard_triggers('stock_movement');

create table stock_balance (
    id                uuid primary key default gen_random_uuid(),
    business_id       uuid not null references business(id),
    branch_id         uuid not null references branch(id),

    stock_item_id     uuid not null references stock_item(id),
    qty_on_hand       app.quantity not null default 0,
    avg_unit_cost     app.money_amount not null default 0,
    value_amount      app.money_amount not null default 0,
    last_movement_at  timestamptz,
    recomputed_at     timestamptz,

    created_at        timestamptz not null default now(),
    created_by        uuid,
    updated_at        timestamptz not null default now(),
    updated_by        uuid,
    deleted_at        timestamptz,
    row_version       integer not null default 1,

    constraint stock_balance_unique unique nulls not distinct (stock_item_id, branch_id, deleted_at)
);

comment on table stock_balance is
    'A materialised balance per item per branch, maintained for speed and fully rebuildable from stock_movement. The movements are the truth; a reconciliation test proves this table agrees with them.';

select app.attach_standard_triggers('stock_balance');

create table stock_transfer (
    id                    uuid primary key default gen_random_uuid(),
    business_id           uuid not null references business(id),
    -- The sending branch owns the document; branch_id follows the convention.
    branch_id             uuid not null references branch(id),

    transfer_no           text not null,
    from_branch_id        uuid not null references branch(id),
    to_branch_id          uuid not null references branch(id),
    -- The outbound half can be recorded offline; the receiving branch must
    -- confirm online, so stock in transit is always visible and never counted
    -- twice (§5.1).
    status                text not null default 'draft'
        constraint stock_transfer_status_valid check (status in ('draft','in_transit','received','cancelled')),
    sent_at               timestamptz,
    sent_by               uuid references app_user(id),
    received_at           timestamptz,
    received_by           uuid references app_user(id),
    notes                 text,

    created_at            timestamptz not null default now(),
    created_by            uuid,
    updated_at            timestamptz not null default now(),
    updated_by            uuid,
    deleted_at            timestamptz,
    row_version           integer not null default 1,

    constraint stock_transfer_no_unique unique nulls not distinct (business_id, transfer_no, deleted_at),
    constraint stock_transfer_branches_differ check (from_branch_id <> to_branch_id),
    constraint stock_transfer_received_coherent check (status <> 'received' or received_at is not null)
);

comment on table stock_transfer is 'Stock moving between outlets. Two halves, so what is in transit is never invisible.';
select app.attach_standard_triggers('stock_transfer');

create table stock_transfer_line (
    id                uuid primary key default gen_random_uuid(),
    business_id       uuid not null references business(id),

    transfer_id       uuid not null references stock_transfer(id),
    stock_item_id     uuid not null references stock_item(id),
    qty_sent          app.quantity not null
        constraint stock_transfer_line_qty_positive check (qty_sent > 0),
    qty_received      app.quantity,
    variance_reason   text,

    created_at        timestamptz not null default now(),
    created_by        uuid,
    updated_at        timestamptz not null default now(),
    updated_by        uuid,
    deleted_at        timestamptz,
    row_version       integer not null default 1,

    constraint stock_transfer_line_unique unique nulls not distinct (transfer_id, stock_item_id, deleted_at),
    -- Receiving less than was sent is possible and must be explained, not
    -- silently absorbed.
    constraint stock_transfer_line_variance_explained check (
        qty_received is null or qty_received = qty_sent or variance_reason is not null
    )
);

comment on table stock_transfer_line is 'What was sent and what actually arrived. A difference requires an explanation.';
select app.attach_standard_triggers('stock_transfer_line');

-- ===========================================================================
-- Customer-owned material — a custody register, not inventory (BR-05)
-- ===========================================================================
create table customer_material (
    id                    uuid primary key default gen_random_uuid(),
    business_id           uuid not null references business(id),
    branch_id             uuid not null references branch(id),

    customer_id           uuid not null references customer(id),
    order_id              uuid references sales_order(id),

    -- Ownership is a stored, checked value rather than an assumption, so a
    -- query that forgets the distinction still cannot get it wrong.
    ownership             text not null default 'customer'
        constraint customer_material_ownership_valid check (ownership = 'customer'),

    description           text not null,
    colour                text,
    qty_received          app.quantity not null
        constraint customer_material_qty_positive check (qty_received > 0),
    uom                   text not null default 'metre',
    condition_notes       text,
    storage_location      text,
    received_at           timestamptz not null default now(),
    received_by           uuid references app_user(id),
    -- The customer's acknowledgment on receipt, and again on return. Leftover
    -- cloth is the classic dispute; an acknowledgment is the answer to it.
    receipt_ack_id        uuid references attachment(id),
    return_ack_id         uuid references attachment(id),

    -- Recorded for insurance and dispute reference ONLY. The column name says
    -- so because a value on a custody record is exactly the thing that must
    -- never leak into a balance sheet (BR-05).
    declared_value_non_accounting app.money_amount,

    status                text not null default 'held'
        constraint customer_material_status_valid check (status in
            ('held','partly_issued','issued','returned','written_off')),

    created_at            timestamptz not null default now(),
    created_by            uuid,
    updated_at            timestamptz not null default now(),
    updated_by            uuid,
    deleted_at            timestamptz,
    row_version           integer not null default 1
);

comment on table customer_material is
    'Cloth the customer brought. A custody obligation, not an asset: it appears in no valuation, no account and no journal entry. If it is lost, compensation is entered as an expense by a person with a reason - the only path by which it can ever touch the books (BR-05).';
comment on column customer_material.declared_value_non_accounting is
    'Reference figure for insurance or a dispute. Deliberately named to be unusable by mistake: nothing in the ledger reads this column.';

create index customer_material_customer_idx on customer_material (customer_id) where deleted_at is null;
create index customer_material_order_idx on customer_material (order_id) where deleted_at is null;
create index customer_material_held_idx on customer_material (branch_id, status) where status <> 'returned' and deleted_at is null;
select app.attach_standard_triggers('customer_material');

create table customer_material_movement (
    id                  uuid primary key default gen_random_uuid(),
    business_id         uuid not null references business(id),
    branch_id           uuid not null references branch(id),

    material_id         uuid not null references customer_material(id),
    movement_type       text not null
        constraint customer_material_movement_type_valid check (movement_type in
            ('received','issued_to_garment','wastage','returned_to_customer','written_off')),
    qty_signed          app.quantity not null
        constraint customer_material_movement_qty_not_zero check (qty_signed <> 0),
    garment_id          uuid references garment(id),
    occurred_at         timestamptz not null default now(),
    performed_by        uuid references app_user(id),
    reason_code         text,
    note                text,
    acknowledgment_id   uuid references attachment(id),

    created_at          timestamptz not null default now(),
    created_by          uuid,
    updated_at          timestamptz not null default now(),
    updated_by          uuid,
    deleted_at          timestamptz,
    row_version         integer not null default 1,

    -- Losing or wasting someone else's cloth always needs an explanation.
    constraint customer_material_movement_loss_needs_reason check (
        movement_type not in ('wastage','written_off') or reason_code is not null
    )
);

comment on table customer_material_movement is
    'Received, issued, wasted, returned. Remaining quantity is the sum of these - the figure shown at delivery so leftover cloth is settled, not forgotten.';

create index customer_material_movement_material_idx on customer_material_movement (material_id, occurred_at);
create index customer_material_movement_garment_idx on customer_material_movement (garment_id) where deleted_at is null;
select app.attach_standard_triggers('customer_material_movement');
