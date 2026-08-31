-- Cluster 2.6 behaviour, and the structural proof of BR-05: customer-owned
-- material cannot become a business asset, because the schema gives it no path.

insert into business (id, legal_name) values ('11111111-1111-1111-1111-111111111111', 'Test Tailors');
insert into branch (id, business_id, code, name)
values ('22222222-2222-2222-2222-222222222222', '11111111-1111-1111-1111-111111111111', 'BR1', 'Main'),
       ('22222222-2222-2222-2222-222222222223', '11111111-1111-1111-1111-111111111111', 'BR2', 'Second');
insert into customer (id, business_id, display_name)
values ('cccccccc-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Imran Khan');

-- ---------------------------------------------------------------------------
-- BR-05: the separation is structural, not a flag
-- ---------------------------------------------------------------------------
select dhaaga_test.eq(
    coalesce((select string_agg(c.conname, ', ')
              from pg_constraint c
              where c.contype = 'f'
                and c.conrelid in ('customer_material'::regclass, 'customer_material_movement'::regclass)
                and c.confrelid in ('journal_entry'::regclass, 'journal_line'::regclass, 'account'::regclass)), ''),
    '', 'BR-05: customer material has no path to the ledger - no foreign key to any accounting table');

select dhaaga_test.eq(
    coalesce((select string_agg(c.conname, ', ')
              from pg_constraint c
              where c.contype = 'f'
                and c.conrelid = 'stock_movement'::regclass
                and c.confrelid = 'customer_material'::regclass), ''),
    '', 'BR-05: a stock movement cannot reference customer material - the columns do not exist');

select dhaaga_test.eq(
    coalesce((select string_agg(a.attname, ', ')
              from pg_attribute a
              where a.attrelid = 'customer_material'::regclass and a.attnum > 0 and not a.attisdropped
                and a.attname in ('unit_cost','total_cost','value_amount','avg_unit_cost')), ''),
    '', 'BR-05: customer material carries no costing column that could feed a valuation');

select dhaaga_test.ok(
    (select true from pg_attribute
     where attrelid = 'customer_material'::regclass and attname = 'declared_value_non_accounting'),
    'the one value field is named so it cannot be mistaken for an accounting figure');

-- Ownership cannot be flipped, even by a direct update.
insert into customer_material (id, business_id, branch_id, customer_id, description, qty_received, uom)
values ('b0000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
        '22222222-2222-2222-2222-222222222222', 'cccccccc-0000-0000-0000-000000000001',
        'Navy wool suiting', 3.500, 'metre');

select dhaaga_test.throws(
    $$update customer_material set ownership = 'business' where id = 'b0000000-0000-0000-0000-000000000001'$$,
    'customer cloth cannot be reclassified as the business''s own', '23514');

-- ---------------------------------------------------------------------------
-- Custody arithmetic: received, issued, wasted, returned, remaining
-- ---------------------------------------------------------------------------
insert into customer_material_movement (business_id, branch_id, material_id, movement_type, qty_signed)
values ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222',
        'b0000000-0000-0000-0000-000000000001', 'received', 3.500),
       ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222',
        'b0000000-0000-0000-0000-000000000001', 'issued_to_garment', -2.800);

insert into customer_material_movement (business_id, branch_id, material_id, movement_type, qty_signed, reason_code)
values ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222',
        'b0000000-0000-0000-0000-000000000001', 'wastage', -0.200, 'cutting_loss');

select dhaaga_test.eq(
    (select sum(qty_signed) from customer_material_movement where material_id = 'b0000000-0000-0000-0000-000000000001'),
    0.500::numeric,
    'half a metre of the customer''s cloth remains - the figure shown at delivery so leftovers are settled');

select dhaaga_test.throws(
    $$insert into customer_material_movement (business_id, branch_id, material_id, movement_type, qty_signed)
      values ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222',
              'b0000000-0000-0000-0000-000000000001', 'wastage', -0.100)$$,
    'wasting someone else''s cloth requires a recorded reason', '23514');

select dhaaga_test.throws(
    $$insert into customer_material_movement (business_id, branch_id, material_id, movement_type, qty_signed)
      values ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222',
              'b0000000-0000-0000-0000-000000000001', 'received', 0)$$,
    'a movement of zero quantity is rejected', '23514');

-- ---------------------------------------------------------------------------
-- Shop stock: balances derive from movements (BR-09)
-- ---------------------------------------------------------------------------
insert into stock_item (id, business_id, code, name, kind, uom)
values ('50000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
        'FAB-NAVY', 'Navy suiting', 'fabric', 'metre');

insert into stock_movement (business_id, branch_id, stock_item_id, movement_type, qty_signed, unit_cost, total_cost)
values ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222',
        '50000000-0000-0000-0000-000000000001', 'purchase', 50.000, 420.00, 21000.00),
       ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222',
        '50000000-0000-0000-0000-000000000001', 'issue', -3.250, 420.00, 1365.00);

select dhaaga_test.eq(
    (select sum(qty_signed) from stock_movement where stock_item_id = '50000000-0000-0000-0000-000000000001' and business_id = '11111111-1111-1111-1111-111111111111'),
    46.750::numeric, 'stock on hand is the sum of signed movements, not an edited number (BR-09)');

select dhaaga_test.throws(
    $$insert into stock_movement (business_id, branch_id, stock_item_id, movement_type, qty_signed)
      values ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222',
              '50000000-0000-0000-0000-000000000001', 'adjustment', -5)$$,
    'a stock adjustment without a reason is refused - this is where stock quietly disappears', '23514');

select dhaaga_test.throws(
    $$insert into stock_movement (business_id, branch_id, stock_item_id, movement_type, qty_signed, reason_code)
      values ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222',
              '50000000-0000-0000-0000-000000000001', 'wastage', -2, null)$$,
    'wastage without a reason is refused', '23514');

-- ---------------------------------------------------------------------------
-- Transfers: two halves, and a variance that must be explained
-- ---------------------------------------------------------------------------
insert into stock_transfer (id, business_id, branch_id, transfer_no, from_branch_id, to_branch_id, status)
values ('70000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
        '22222222-2222-2222-2222-222222222222', 'TR-001',
        '22222222-2222-2222-2222-222222222222', '22222222-2222-2222-2222-222222222223', 'in_transit');

select dhaaga_test.throws(
    $$insert into stock_transfer (business_id, branch_id, transfer_no, from_branch_id, to_branch_id)
      values ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222', 'TR-002',
              '22222222-2222-2222-2222-222222222222', '22222222-2222-2222-2222-222222222222')$$,
    'a branch cannot transfer stock to itself', '23514');

select dhaaga_test.throws(
    $$update stock_transfer set status = 'received' where transfer_no = 'TR-001' and business_id = '11111111-1111-1111-1111-111111111111'$$,
    'a transfer cannot be marked received without recording when', '23514');

insert into stock_transfer_line (business_id, transfer_id, stock_item_id, qty_sent)
values ('11111111-1111-1111-1111-111111111111', '70000000-0000-0000-0000-000000000001',
        '50000000-0000-0000-0000-000000000001', 10.000);

select dhaaga_test.throws(
    $$update stock_transfer_line set qty_received = 8.000
      where transfer_id = '70000000-0000-0000-0000-000000000001'$$,
    'receiving less than was sent must be explained, not silently absorbed', '23514');

select dhaaga_test.lives(
    $$update stock_transfer_line set qty_received = 8.000, variance_reason = 'short roll'
      where transfer_id = '70000000-0000-0000-0000-000000000001'$$,
    'a variance with an explanation is accepted');
