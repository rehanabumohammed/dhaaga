-- 0007 · Finance
--
-- Cluster 2.5 of the blueprint. The append-only double-entry ledger that makes
-- revenue, collections, receivables, advances, profit and cash flow distinct
-- concepts rather than one number wearing different labels.
--
-- Nobody in the shop ever sees this. Staff take an advance, hand over a
-- garment, collect a balance and close a drawer; a domain service turns each of
-- those into a document and a balanced journal entry (AP-2, BR-23).
--
-- Two things are deliberately NOT in this migration, because they belong to
-- WP-5 (Ledger core and immutability) and are tested there:
--   * the entry-level balance constraint (sum of debits = sum of credits),
--     which needs a deferred constraint trigger;
--   * the revocation of UPDATE and DELETE on posted rows from the application
--     role, which is a grant, not a table definition.
-- Everything a column or a row-level constraint can express is here.

-- ===========================================================================
-- Chart of accounts
-- ===========================================================================
create table account (
    id                uuid primary key default gen_random_uuid(),
    business_id       uuid not null references business(id),

    code              text not null,
    name              text not null,
    account_type      text not null
        constraint account_type_valid check (account_type in
            ('asset','liability','equity','revenue','direct_cost','expense','control')),
    -- Which side increases this account. Stored rather than inferred from type
    -- because contra accounts invert it, and getting this wrong silently
    -- reverses a whole report.
    normal_balance    text not null
        constraint account_normal_balance_valid check (normal_balance in ('debit','credit')),
    -- Discounts allowed and sales returns reduce revenue without being expenses.
    -- Keeping them as contra-revenue is what makes discount leakage measurable
    -- (BR-20).
    is_contra         boolean not null default false,
    parent_id         uuid references account(id),
    -- System accounts are seeded and cannot be deleted; the owner may still add
    -- their own expense accounts freely (AP-1).
    is_system         boolean not null default false,
    is_active         boolean not null default true,
    description       text,

    created_at        timestamptz not null default now(),
    created_by        uuid,
    updated_at        timestamptz not null default now(),
    updated_by        uuid,
    deleted_at        timestamptz,
    row_version       integer not null default 1,

    constraint account_not_own_parent check (parent_id is null or parent_id <> id)
);

comment on table account is
    'The chart of accounts, seeded per business. Cash is one account; per-branch cash comes from the branch dimension on the journal line, not from a separate account per outlet.';
comment on column account.is_contra is
    'A contra account reduces its group without leaving it. Discounts allowed sits under revenue and reduces it (BR-20).';

create unique index account_code_unique on account (business_id, code) where deleted_at is null;
select app.attach_standard_triggers('account');

-- ===========================================================================
-- Accounting periods
-- ===========================================================================
create table accounting_period (
    id                uuid primary key default gen_random_uuid(),
    business_id       uuid not null references business(id),

    code              text not null,
    starts_on         date not null,
    ends_on           date not null,
    status            text not null default 'open'
        constraint accounting_period_status_valid check (status in ('open','closed','locked')),
    closed_at         timestamptz,
    locked_at         timestamptz,
    locked_by         uuid references app_user(id),

    created_at        timestamptz not null default now(),
    created_by        uuid,
    updated_at        timestamptz not null default now(),
    updated_by        uuid,
    deleted_at        timestamptz,
    row_version       integer not null default 1,

    constraint accounting_period_range_valid check (ends_on >= starts_on),
    constraint accounting_period_locked_coherent check (status <> 'locked' or locked_at is not null)
);

comment on table accounting_period is
    'A month or a year. A locked period accepts no postings: corrections go to the current period as reversals (§4).';

create unique index accounting_period_code_unique on accounting_period (business_id, code) where deleted_at is null;

-- Periods cannot overlap, or "which period does this entry belong to" has more
-- than one answer.
alter table accounting_period
    add constraint accounting_period_no_overlap
    exclude using gist (
        business_id with =,
        daterange(starts_on, ends_on, '[]') with &&
    ) where (deleted_at is null);

select app.attach_standard_triggers('accounting_period');

-- ===========================================================================
-- The ledger
-- ===========================================================================
create table journal_entry (
    id                uuid primary key default gen_random_uuid(),
    business_id       uuid not null references business(id),
    branch_id         uuid references branch(id),

    entry_no          text,
    period_id         uuid references accounting_period(id),
    entry_date        date not null default current_date,

    -- What business event produced this. Every entry traces back to a document
    -- a person can recognise; there are no free-floating adjustments except the
    -- ones an owner makes deliberately, which say so here.
    source_doc_type   text not null
        constraint journal_entry_source_valid check (source_doc_type in
            ('invoice','payment','credit_note','delivery','stock_issue','stock_adjustment',
             'purchase_bill','expense','wage_accrual','wage_payout','cash_session',
             'opening_balance','manual_adjustment')),
    source_doc_id     uuid,
    memo              text,

    -- A reversal never edits its original: it is a new entry that mirrors it
    -- (BR-04). Both remain visible forever.
    reversal_of_id    uuid references journal_entry(id),
    reversal_reason_code text,
    reversal_reason_text text,

    posted_at         timestamptz not null default now(),
    posted_by         uuid references app_user(id),

    created_at        timestamptz not null default now(),
    created_by        uuid,
    updated_at        timestamptz not null default now(),
    updated_by        uuid,
    deleted_at        timestamptz,
    row_version       integer not null default 1,

    constraint journal_entry_not_own_reversal check (reversal_of_id is null or reversal_of_id <> id),
    constraint journal_entry_reversal_has_reason check (reversal_of_id is null or reversal_reason_code is not null)
);

comment on table journal_entry is
    'One balanced accounting event. Immutable once posted: UPDATE and DELETE are revoked from the application role in WP-5, and corrections are reversals (BR-04).';
comment on column journal_entry.reversal_of_id is
    'Set on the mirroring entry that cancels another. A reversal without a recorded reason is refused.';

create index journal_entry_period_idx on journal_entry (period_id, entry_date) where deleted_at is null;
create index journal_entry_source_idx on journal_entry (source_doc_type, source_doc_id) where deleted_at is null;
create index journal_entry_branch_date_idx on journal_entry (branch_id, entry_date) where deleted_at is null;
select app.attach_standard_triggers('journal_entry');

create table journal_line (
    id                uuid primary key default gen_random_uuid(),
    business_id       uuid not null references business(id),
    -- The dimension that splits the profit and loss by outlet without a second
    -- set of books (§1).
    branch_id         uuid references branch(id),

    entry_id          uuid not null references journal_entry(id),
    account_id        uuid not null references account(id),
    line_no           integer not null default 1,

    debit             app.money_amount not null default 0,
    credit            app.money_amount not null default 0,

    -- Analytical dimensions. Every report in the KPI appendix is a query over
    -- these rather than a separately maintained summary (AP-8).
    customer_id       uuid references customer(id),
    supplier_id       uuid,
    garment_id        uuid references garment(id),
    staff_id          uuid references app_user(id),
    stock_item_id     uuid,
    memo              text,

    created_at        timestamptz not null default now(),
    created_by        uuid,
    updated_at        timestamptz not null default now(),
    updated_by        uuid,
    deleted_at        timestamptz,
    row_version       integer not null default 1,

    -- A line is a debit or a credit, never both and never neither. Sign errors
    -- become impossible rather than merely unlikely.
    constraint journal_line_amounts_non_negative check (debit >= 0 and credit >= 0),
    constraint journal_line_exactly_one_side check (
        (debit > 0 and credit = 0) or (credit > 0 and debit = 0)
    )
);

comment on table journal_line is
    'One side of an entry, carrying the dimensions that make reporting derivable: branch, customer, garment, staff, supplier, stock item.';

create index journal_line_entry_idx on journal_line (entry_id) where deleted_at is null;
create index journal_line_account_idx on journal_line (account_id) where deleted_at is null;
create index journal_line_customer_idx on journal_line (customer_id) where deleted_at is null;
create index journal_line_garment_idx on journal_line (garment_id) where deleted_at is null;
create index journal_line_staff_idx on journal_line (staff_id) where deleted_at is null;
select app.attach_standard_triggers('journal_line');

-- ===========================================================================
-- Cash sessions — the drawer
-- ===========================================================================
create table cash_session (
    id                uuid primary key default gen_random_uuid(),
    business_id       uuid not null references business(id),
    branch_id         uuid not null references branch(id),

    user_id           uuid not null references app_user(id),
    opened_at         timestamptz not null default now(),
    opening_float     app.money_amount not null default 0,
    closed_at         timestamptz,
    -- What the system believes should be in the drawer, what was actually
    -- counted, and the gap. The gap is surfaced, never absorbed (§4).
    expected_amount   app.money_amount,
    counted_amount    app.money_amount,
    difference_amount app.money_amount,
    status            text not null default 'open'
        constraint cash_session_status_valid check (status in ('open','closed','reconciled')),
    notes             text,
    journal_entry_id  uuid references journal_entry(id),

    created_at        timestamptz not null default now(),
    created_by        uuid,
    updated_at        timestamptz not null default now(),
    updated_by        uuid,
    deleted_at        timestamptz,
    row_version       integer not null default 1,

    constraint cash_session_float_non_negative check (opening_float >= 0),
    constraint cash_session_closed_coherent check (
        status = 'open' or (closed_at is not null and counted_amount is not null)
    )
);

comment on table cash_session is
    'An open drawer for one branch, one day, one person. Closing it requires a counted amount - a close without a count is not a close.';

-- One open drawer per person per branch: two open sessions make the expected
-- amount meaningless.
create unique index cash_session_one_open on cash_session (branch_id, user_id)
    where status = 'open' and deleted_at is null;
select app.attach_standard_triggers('cash_session');

-- ===========================================================================
-- Invoices
-- ===========================================================================
create table invoice (
    id                    uuid primary key default gen_random_uuid(),
    business_id           uuid not null references business(id),
    branch_id             uuid not null references branch(id),

    invoice_no            text not null,
    doc_type              text not null default 'tax_invoice'
        constraint invoice_doc_type_valid check (doc_type in ('tax_invoice','bill_of_supply','estimate')),
    order_id              uuid references sales_order(id),
    delivery_note_id      uuid references delivery_note(id),
    customer_id           uuid not null references customer(id),
    bill_to_household_id  uuid references household(id),

    invoice_date          date not null default current_date,
    tax_profile_id        uuid references tax_profile(id),
    place_of_supply       text,
    pricing_mode          text not null default 'exclusive'
        constraint invoice_pricing_mode_valid check (pricing_mode in ('inclusive','exclusive')),

    -- Unlike an order, an invoice stores its totals. It is a document: a record
    -- of what was printed and handed to a customer, and it must reproduce
    -- identically years later even if a price list or tax rate has moved.
    subtotal_amount       app.money_amount not null default 0,
    discount_amount       app.money_amount not null default 0,
    taxable_amount        app.money_amount not null default 0,
    tax_amount            app.money_amount not null default 0,
    rounding_amount       app.money_amount not null default 0,
    total_amount          app.money_amount not null default 0,

    -- Until a current CA sign-off covers the tax configuration, tax documents
    -- print watermarked as drafts (BR-22).
    is_draft_watermarked  boolean not null default true,
    status                text not null default 'issued'
        constraint invoice_status_valid check (status in ('draft','issued','cancelled')),
    journal_entry_id      uuid references journal_entry(id),
    notes                 text,

    created_at            timestamptz not null default now(),
    created_by            uuid,
    updated_at            timestamptz not null default now(),
    updated_by            uuid,
    deleted_at            timestamptz,
    row_version           integer not null default 1,

    constraint invoice_no_unique unique nulls not distinct (branch_id, invoice_no, deleted_at),
    constraint invoice_amounts_non_negative check (
        subtotal_amount >= 0 and discount_amount >= 0 and taxable_amount >= 0
        and tax_amount >= 0 and total_amount >= 0
    )
);

comment on table invoice is
    'A tax document. Totals are stored because the document must reprint identically years later - this is a record, not a cache (contrast sales_order, whose totals are derived).';
comment on column invoice.is_draft_watermarked is
    'True until a current CA sign-off covers the tax configuration in force (BR-22).';

create index invoice_customer_idx on invoice (customer_id) where deleted_at is null;
create index invoice_order_idx on invoice (order_id) where deleted_at is null;
create index invoice_date_idx on invoice (branch_id, invoice_date) where deleted_at is null;
select app.attach_standard_triggers('invoice');

create table invoice_line (
    id                uuid primary key default gen_random_uuid(),
    business_id       uuid not null references business(id),

    invoice_id        uuid not null references invoice(id),
    line_no           integer not null default 1,
    garment_id        uuid references garment(id),
    order_item_id     uuid references order_item(id),
    stock_item_id     uuid,

    description       text not null,
    hsn_sac           text,
    quantity          numeric(12,3) not null default 1,
    unit_price        app.money_amount not null default 0,
    discount_amount   app.money_amount not null default 0,

    tax_code_id       uuid references tax_code(id),
    -- The rate that applied when this document was issued, copied in. BR-15 is
    -- honoured by the copy, not by a lookup at print time.
    tax_rate_id       uuid references tax_rate(id),
    tax_percent       app.rate_percent not null default 0,
    taxable_amount    app.money_amount not null default 0,
    tax_amount        app.money_amount not null default 0,
    total_amount      app.money_amount not null default 0,

    created_at        timestamptz not null default now(),
    created_by        uuid,
    updated_at        timestamptz not null default now(),
    updated_by        uuid,
    deleted_at        timestamptz,
    row_version       integer not null default 1,

    constraint invoice_line_amounts_non_negative check (
        unit_price >= 0 and discount_amount >= 0 and taxable_amount >= 0
        and tax_amount >= 0 and total_amount >= 0
    ),
    constraint invoice_line_quantity_positive check (quantity > 0)
);

comment on table invoice_line is
    'One printed line, with the tax rate that applied at issue copied in rather than looked up later (BR-15).';

create index invoice_line_invoice_idx on invoice_line (invoice_id) where deleted_at is null;
create index invoice_line_garment_idx on invoice_line (garment_id) where deleted_at is null;
select app.attach_standard_triggers('invoice_line');

create table credit_note (
    id                uuid primary key default gen_random_uuid(),
    business_id       uuid not null references business(id),
    branch_id         uuid not null references branch(id),

    note_no           text not null,
    invoice_id        uuid not null references invoice(id),
    customer_id       uuid not null references customer(id),
    note_date         date not null default current_date,
    reason_code       text not null,
    reason_text       text,

    taxable_amount    app.money_amount not null default 0,
    tax_amount        app.money_amount not null default 0,
    total_amount      app.money_amount not null default 0,
    journal_entry_id  uuid references journal_entry(id),

    created_at        timestamptz not null default now(),
    created_by        uuid,
    updated_at        timestamptz not null default now(),
    updated_by        uuid,
    deleted_at        timestamptz,
    row_version       integer not null default 1,

    constraint credit_note_no_unique unique nulls not distinct (branch_id, note_no, deleted_at),
    constraint credit_note_amounts_non_negative check (
        taxable_amount >= 0 and tax_amount >= 0 and total_amount >= 0
    )
);

comment on table credit_note is
    'The correction document for an issued invoice. An invoice is never edited; a credit note says what changed and why.';
select app.attach_standard_triggers('credit_note');

-- ===========================================================================
-- Payments
-- ===========================================================================
create table payment_mode (
    id                    uuid primary key default gen_random_uuid(),
    business_id           uuid not null references business(id),

    code                  text not null,
    label                 text not null,
    account_id            uuid not null references account(id),
    requires_reference    boolean not null default false,
    is_cash               boolean not null default false,
    settles_immediately   boolean not null default true,
    is_active             boolean not null default true,
    sort_order            integer not null default 100,

    created_at            timestamptz not null default now(),
    created_by            uuid,
    updated_at            timestamptz not null default now(),
    updated_by            uuid,
    deleted_at            timestamptz,
    row_version           integer not null default 1,

    constraint payment_mode_code_unique unique nulls not distinct (business_id, code, deleted_at)
);

comment on table payment_mode is
    'Cash, UPI, card, bank transfer, cheque - each mapped to an account. Adding "Paytm QR - Branch 2" is configuration, not a release (AP-1).';
select app.attach_standard_triggers('payment_mode');

create table payment (
    id                uuid primary key default gen_random_uuid(),
    business_id       uuid not null references business(id),
    branch_id         uuid not null references branch(id),

    payment_no        text,
    direction         text not null
        constraint payment_direction_valid check (direction in ('in','out')),
    customer_id       uuid references customer(id),
    supplier_id       uuid,
    staff_id          uuid references app_user(id),

    amount            app.money_amount not null
        constraint payment_amount_positive check (amount > 0),
    mode_id           uuid not null references payment_mode(id),
    reference         text,
    occurred_at       timestamptz not null default now(),
    received_by       uuid references app_user(id),
    cash_session_id   uuid references cash_session(id),

    -- A payment is never edited. A mistake is reversed: the original stays,
    -- marked, and a mirrored payment cancels it (§4).
    status            text not null default 'posted'
        constraint payment_status_valid check (status in ('posted','reversed')),
    reversal_of_id    uuid references payment(id),
    reversal_reason_code text,
    journal_entry_id  uuid references journal_entry(id),
    notes             text,

    created_at        timestamptz not null default now(),
    created_by        uuid,
    updated_at        timestamptz not null default now(),
    updated_by        uuid,
    deleted_at        timestamptz,
    row_version       integer not null default 1,

    constraint payment_not_own_reversal check (reversal_of_id is null or reversal_of_id <> id),
    constraint payment_reversal_has_reason check (reversal_of_id is null or reversal_reason_code is not null),
    -- Money comes from a customer or goes to a supplier or a staff member. A
    -- payment attached to nobody cannot be reconciled with anything.
    constraint payment_has_a_counterparty check (
        customer_id is not null or supplier_id is not null or staff_id is not null
    )
);

comment on table payment is
    'Money in or out, with an immutable history. Correction is by reversal only; the id is client-generated so an offline replay is a no-op (§5.2).';

create index payment_customer_idx on payment (customer_id, occurred_at desc) where deleted_at is null;
create index payment_session_idx on payment (cash_session_id) where deleted_at is null;
create index payment_branch_date_idx on payment (branch_id, occurred_at desc) where deleted_at is null;
select app.attach_standard_triggers('payment');

create table payment_allocation (
    id                uuid primary key default gen_random_uuid(),
    business_id       uuid not null references business(id),

    payment_id        uuid not null references payment(id),
    -- A payment applies to an invoice, or to an order before one exists. What
    -- is not applied stays as a customer credit balance - a liability, not a
    -- receivable (§4).
    invoice_id        uuid references invoice(id),
    order_id          uuid references sales_order(id),
    amount            app.money_amount not null
        constraint payment_allocation_amount_positive check (amount > 0),
    allocated_at      timestamptz not null default now(),

    created_at        timestamptz not null default now(),
    created_by        uuid,
    updated_at        timestamptz not null default now(),
    updated_by        uuid,
    deleted_at        timestamptz,
    row_version       integer not null default 1,

    constraint payment_allocation_target_exactly_one check (
        (invoice_id is not null and order_id is null) or
        (invoice_id is null and order_id is not null)
    )
);

comment on table payment_allocation is
    'Which debt a payment settles. Its own table because one payment may settle four family orders, and one order may take six payments.';

create index payment_allocation_payment_idx on payment_allocation (payment_id) where deleted_at is null;
create index payment_allocation_invoice_idx on payment_allocation (invoice_id) where deleted_at is null;
create index payment_allocation_order_idx on payment_allocation (order_id) where deleted_at is null;
select app.attach_standard_triggers('payment_allocation');

-- ===========================================================================
-- Suppliers, purchases, expenses
-- ===========================================================================
create table supplier (
    id                uuid primary key default gen_random_uuid(),
    business_id       uuid not null references business(id),

    name              text not null,
    gstin             text,
    phone_e164        text,
    email             text,
    address_line1     text,
    city              text,
    state_code        text,
    notes             text,
    is_active         boolean not null default true,

    created_at        timestamptz not null default now(),
    created_by        uuid,
    updated_at        timestamptz not null default now(),
    updated_by        uuid,
    deleted_at        timestamptz,
    row_version       integer not null default 1
);

comment on table supplier is 'Who you buy fabric, trims and services from.';
create index supplier_business_idx on supplier (business_id) where deleted_at is null;
select app.attach_standard_triggers('supplier');

create table purchase_bill (
    id                uuid primary key default gen_random_uuid(),
    business_id       uuid not null references business(id),
    branch_id         uuid not null references branch(id),

    supplier_id       uuid not null references supplier(id),
    bill_no           text not null,
    bill_date         date not null default current_date,
    due_date          date,
    subtotal_amount   app.money_amount not null default 0,
    tax_amount        app.money_amount not null default 0,
    total_amount      app.money_amount not null default 0,
    status            text not null default 'open'
        constraint purchase_bill_status_valid check (status in ('draft','open','paid','cancelled')),
    journal_entry_id  uuid references journal_entry(id),
    notes             text,

    created_at        timestamptz not null default now(),
    created_by        uuid,
    updated_at        timestamptz not null default now(),
    updated_by        uuid,
    deleted_at        timestamptz,
    row_version       integer not null default 1,

    constraint purchase_bill_unique unique nulls not distinct (supplier_id, bill_no, deleted_at),
    constraint purchase_bill_amounts_non_negative check (
        subtotal_amount >= 0 and tax_amount >= 0 and total_amount >= 0
    )
);

comment on table purchase_bill is 'A supplier invoice. Creates a payable; paying it is a separate event.';
select app.attach_standard_triggers('purchase_bill');

create table purchase_bill_line (
    id                uuid primary key default gen_random_uuid(),
    business_id       uuid not null references business(id),

    purchase_bill_id  uuid not null references purchase_bill(id),
    line_no           integer not null default 1,
    stock_item_id     uuid,
    description       text not null,
    quantity          app.quantity not null
        constraint purchase_bill_line_quantity_positive check (quantity > 0),
    unit_cost         app.money_amount not null default 0,
    tax_code_id       uuid references tax_code(id),
    tax_amount        app.money_amount not null default 0,
    total_amount      app.money_amount not null default 0,

    created_at        timestamptz not null default now(),
    created_by        uuid,
    updated_at        timestamptz not null default now(),
    updated_by        uuid,
    deleted_at        timestamptz,
    row_version       integer not null default 1
);

comment on table purchase_bill_line is 'What was bought, at what cost - the source of weighted average cost for stock valuation.';
create index purchase_bill_line_bill_idx on purchase_bill_line (purchase_bill_id) where deleted_at is null;
select app.attach_standard_triggers('purchase_bill_line');

create table expense (
    id                uuid primary key default gen_random_uuid(),
    business_id       uuid not null references business(id),
    branch_id         uuid references branch(id),

    account_id        uuid not null references account(id),
    supplier_id       uuid references supplier(id),
    expense_date      date not null default current_date,
    amount            app.money_amount not null
        constraint expense_amount_positive check (amount > 0),
    tax_amount        app.money_amount not null default 0,
    paid_via_mode_id  uuid references payment_mode(id),
    reference         text,
    description       text,
    journal_entry_id  uuid references journal_entry(id),

    created_at        timestamptz not null default now(),
    created_by        uuid,
    updated_at        timestamptz not null default now(),
    updated_by        uuid,
    deleted_at        timestamptz,
    row_version       integer not null default 1
);

comment on table expense is
    'Rent, electricity, transport - and the one route by which customer-owned material can ever touch the books: compensation for loss, entered by a person with a reason (BR-05).';

create index expense_branch_date_idx on expense (branch_id, expense_date) where deleted_at is null;
select app.attach_standard_triggers('expense');

-- ===========================================================================
-- Wages
-- ===========================================================================
create table wage_scheme (
    id                uuid primary key default gen_random_uuid(),
    business_id       uuid not null references business(id),

    user_id           uuid not null references app_user(id),
    scheme_type       text not null
        constraint wage_scheme_type_valid check (scheme_type in ('piece_rate','salary','hybrid','contractor')),
    monthly_amount    app.money_amount not null default 0
        constraint wage_scheme_monthly_non_negative check (monthly_amount >= 0),
    effective_from    date not null,
    effective_to      date,

    created_at        timestamptz not null default now(),
    created_by        uuid,
    updated_at        timestamptz not null default now(),
    updated_by        uuid,
    deleted_at        timestamptz,
    row_version       integer not null default 1,

    constraint wage_scheme_range_valid check (effective_to is null or effective_to > effective_from)
);

comment on table wage_scheme is
    'How one person is paid, over a period. All four schemes are supported; a salaried floor still attributes cost per garment or gross profit by garment type is fiction.';

alter table wage_scheme
    add constraint wage_scheme_no_overlap
    exclude using gist (
        user_id with =,
        daterange(effective_from, effective_to) with &&
    ) where (deleted_at is null);

select app.attach_standard_triggers('wage_scheme');

create table wage_rate (
    id                uuid primary key default gen_random_uuid(),
    business_id       uuid not null references business(id),

    -- Null user means the default rate for this garment type and stage; a row
    -- with a user overrides it for that person.
    user_id           uuid references app_user(id),
    garment_type_id   uuid not null references garment_type(id),
    stage_id          uuid references workflow_stage(id),
    amount            app.money_amount not null
        constraint wage_rate_amount_non_negative check (amount >= 0),
    effective_from    date not null,
    effective_to      date,

    created_at        timestamptz not null default now(),
    created_by        uuid,
    updated_at        timestamptz not null default now(),
    updated_by        uuid,
    deleted_at        timestamptz,
    row_version       integer not null default 1,

    constraint wage_rate_range_valid check (effective_to is null or effective_to > effective_from)
);

comment on table wage_rate is
    'What a stage of a garment type earns. Effective-dated, so raising a rate never restates what past work paid.';

create index wage_rate_lookup_idx on wage_rate (garment_type_id, stage_id, effective_from) where deleted_at is null;
select app.attach_standard_triggers('wage_rate');

create table wage_payout (
    id                    uuid primary key default gen_random_uuid(),
    business_id           uuid not null references business(id),
    branch_id             uuid not null references branch(id),

    payout_no             text,
    user_id               uuid not null references app_user(id),
    period_start          date not null,
    period_end            date not null,
    gross_amount          app.money_amount not null default 0,
    deduction_amount      app.money_amount not null default 0,
    advance_recovered     app.money_amount not null default 0,
    net_amount            app.money_amount not null default 0,
    status                text not null default 'draft'
        constraint wage_payout_status_valid check (status in ('draft','locked','paid','cancelled')),
    locked_at             timestamptz,
    paid_at               timestamptz,
    payment_id            uuid references payment(id),
    journal_entry_id      uuid references journal_entry(id),

    created_at            timestamptz not null default now(),
    created_by            uuid,
    updated_at            timestamptz not null default now(),
    updated_by            uuid,
    deleted_at            timestamptz,
    row_version           integer not null default 1,

    constraint wage_payout_period_valid check (period_end >= period_start),
    constraint wage_payout_amounts_non_negative check (
        gross_amount >= 0 and deduction_amount >= 0 and advance_recovered >= 0
    ),
    constraint wage_payout_locked_coherent check (status = 'draft' or locked_at is not null)
);

comment on table wage_payout is
    'A payout run for one person over one period. Locking it freezes what was owed; paying it is a separate event with its own payment row.';

create index wage_payout_user_idx on wage_payout (user_id, period_end desc) where deleted_at is null;
select app.attach_standard_triggers('wage_payout');

create table wage_entry (
    id                  uuid primary key default gen_random_uuid(),
    business_id         uuid not null references business(id),
    branch_id           uuid not null references branch(id),

    user_id             uuid not null references app_user(id),
    production_task_id  uuid references production_task(id),
    garment_id          uuid references garment(id),
    alteration_id       uuid references alteration(id),

    amount              app.money_amount not null,
    earned_at           timestamptz not null default now(),
    -- An adjustment is a separate entry with a reason, never an edit to what
    -- was earned.
    kind                text not null default 'piece_rate'
        constraint wage_entry_kind_valid check (kind in ('piece_rate','salary','bonus','adjustment','penalty')),
    reason_code         text,
    reason_text         text,

    payout_id           uuid references wage_payout(id),
    journal_entry_id    uuid references journal_entry(id),

    created_at          timestamptz not null default now(),
    created_by          uuid,
    updated_at          timestamptz not null default now(),
    updated_by          uuid,
    deleted_at          timestamptz,
    row_version         integer not null default 1,

    -- Only an adjustment or a penalty may be negative, and either must say why.
    constraint wage_entry_negative_needs_reason check (
        amount >= 0 or (kind in ('adjustment','penalty') and reason_code is not null)
    )
);

comment on table wage_entry is
    'What one person earned for one piece of work. Accrues when the task completes, independent of whether the customer has paid (BR-16).';

create index wage_entry_user_idx on wage_entry (user_id, earned_at desc) where deleted_at is null;
create index wage_entry_payout_idx on wage_entry (payout_id) where deleted_at is null;
create index wage_entry_task_idx on wage_entry (production_task_id) where deleted_at is null;
-- A completed task earns once. Without this, a re-sync or a double completion
-- pays a tailor twice for the same garment.
create unique index wage_entry_one_per_task on wage_entry (production_task_id)
    where production_task_id is not null and kind = 'piece_rate' and deleted_at is null;
select app.attach_standard_triggers('wage_entry');

create table staff_advance (
    id                uuid primary key default gen_random_uuid(),
    business_id       uuid not null references business(id),
    branch_id         uuid not null references branch(id),

    user_id           uuid not null references app_user(id),
    amount            app.money_amount not null
        constraint staff_advance_amount_positive check (amount > 0),
    recovered_amount  app.money_amount not null default 0
        constraint staff_advance_recovered_non_negative check (recovered_amount >= 0),
    given_at          timestamptz not null default now(),
    payment_id        uuid references payment(id),
    status            text not null default 'outstanding'
        constraint staff_advance_status_valid check (status in ('outstanding','partly_recovered','recovered','written_off')),
    notes             text,

    created_at        timestamptz not null default now(),
    created_by        uuid,
    updated_at        timestamptz not null default now(),
    updated_by        uuid,
    deleted_at        timestamptz,
    row_version       integer not null default 1,

    constraint staff_advance_not_over_recovered check (recovered_amount <= amount)
);

comment on table staff_advance is
    'Money advanced to a karigar against future work, recovered from payouts. Over-recovery is impossible by constraint.';

create index staff_advance_user_idx on staff_advance (user_id) where deleted_at is null and status <> 'recovered';
select app.attach_standard_triggers('staff_advance');
