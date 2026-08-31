-- Cluster 2.4 behaviour: the order/garment split, allocation arithmetic,
-- override completeness and capacity integrity.

insert into business (id, legal_name) values ('11111111-1111-1111-1111-111111111111', 'Test Tailors');
insert into branch (id, business_id, code, name)
values ('22222222-2222-2222-2222-222222222222', '11111111-1111-1111-1111-111111111111', 'BR1', 'Main');
insert into app_user (id, business_id, full_name)
values ('77777777-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Imran (tailor)'),
       ('77777777-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'Sana (tailor)');
insert into customer (id, business_id, customer_code, display_name)
values ('cccccccc-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'C-000001', 'Imran Khan');
insert into garment_type (id, business_id, code, name)
values ('dddddddd-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'SHIRT', 'Shirt'),
       ('dddddddd-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'TROUSER', 'Trouser');

-- ---------------------------------------------------------------------------
-- The §4 worked example, represented exactly
-- 3 shirts @ 600 + 2 trousers @ 900, 100 discount, order net 3,500
-- ---------------------------------------------------------------------------
insert into sales_order (id, business_id, branch_id, order_no, customer_id, lifecycle, confirmed_at)
values ('0a000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
        '22222222-2222-2222-2222-222222222222', 'ORD-0042', 'cccccccc-0000-0000-0000-000000000001',
        'confirmed', now());

insert into order_item (id, business_id, branch_id, order_id, garment_type_id, quantity, unit_price, discount_amount, line_no)
values ('0b000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222',
        '0a000000-0000-0000-0000-000000000001', 'dddddddd-0000-0000-0000-000000000001', 3, 600.00, 50.00, 1),
       ('0b000000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222',
        '0a000000-0000-0000-0000-000000000001', 'dddddddd-0000-0000-0000-000000000002', 2, 900.00, 50.00, 2);

-- BR-07: quantity creates rows. Three shirts are three garments, and the
-- rounding remainder falls on the last piece.
insert into garment (id, business_id, branch_id, order_item_id, garment_no, piece_no, allocated_amount, promised_date_original, promised_date_current)
values ('0c000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222',
        '0b000000-0000-0000-0000-000000000001', 'ORD-0042-G01', 1, 583.33, '2026-09-05', '2026-09-05'),
       ('0c000000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222',
        '0b000000-0000-0000-0000-000000000001', 'ORD-0042-G02', 2, 583.33, '2026-09-05', '2026-09-05'),
       ('0c000000-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222',
        '0b000000-0000-0000-0000-000000000001', 'ORD-0042-G03', 3, 583.34, '2026-09-05', '2026-09-05'),
       ('0c000000-0000-0000-0000-000000000004', '11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222',
        '0b000000-0000-0000-0000-000000000002', 'ORD-0042-G04', 1, 875.00, '2026-09-08', '2026-09-08'),
       ('0c000000-0000-0000-0000-000000000005', '11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222',
        '0b000000-0000-0000-0000-000000000002', 'ORD-0042-G05', 2, 875.00, '2026-09-08', '2026-09-08');

select dhaaga_test.eq(
    (select count(*)::int from garment g join order_item i on i.id = g.order_item_id
     where i.order_id = '0a000000-0000-0000-0000-000000000001'),
    5, 'BR-07: five garments from two priced lines');

select dhaaga_test.eq(
    (select sum(g.allocated_amount) from garment g where g.order_item_id = '0b000000-0000-0000-0000-000000000001'),
    1750.00::numeric, 'shirt allocations sum exactly to the net line - the remainder is not lost');

select dhaaga_test.eq(
    (select sum(g.allocated_amount) from garment g join order_item i on i.id = g.order_item_id
     where i.order_id = '0a000000-0000-0000-0000-000000000001'),
    3500.00::numeric, 'garment allocations sum exactly to the order net total');

-- Partial delivery: two shirts go home, three pieces stay on the floor.
insert into delivery_note (id, business_id, branch_id, note_no, order_id, received_by_name)
values ('0d000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
        '22222222-2222-2222-2222-222222222222', 'DN-1', '0a000000-0000-0000-0000-000000000001', 'Imran Khan');

insert into delivery_line (business_id, delivery_note_id, garment_id)
values ('11111111-1111-1111-1111-111111111111', '0d000000-0000-0000-0000-000000000001', '0c000000-0000-0000-0000-000000000001'),
       ('11111111-1111-1111-1111-111111111111', '0d000000-0000-0000-0000-000000000001', '0c000000-0000-0000-0000-000000000002');

update garment set lifecycle = 'delivered', delivered_at = now()
where id in ('0c000000-0000-0000-0000-000000000001','0c000000-0000-0000-0000-000000000002');

select dhaaga_test.eq(
    (select sum(allocated_amount) from garment where lifecycle = 'delivered' and business_id = '11111111-1111-1111-1111-111111111111'),
    1166.66::numeric, 'delivered value is exactly the sum of the pieces handed over');

select dhaaga_test.eq(
    (select sum(allocated_amount) from garment g join order_item i on i.id = g.order_item_id
     where i.order_id = '0a000000-0000-0000-0000-000000000001' and g.lifecycle <> 'delivered'),
    2333.34::numeric, 'remaining value is the order net less what was delivered');

select dhaaga_test.throws(
    $$insert into delivery_line (business_id, delivery_note_id, garment_id)
      values ('11111111-1111-1111-1111-111111111111', '0d000000-0000-0000-0000-000000000001',
              '0c000000-0000-0000-0000-000000000001')$$,
    'a garment cannot appear twice in the same direction on one delivery note', '23505');

select dhaaga_test.eq(
    (select promised_date_original from garment where garment_no = 'ORD-0042-G01' and business_id = '11111111-1111-1111-1111-111111111111'),
    '2026-09-05'::date,
    'the original promise survives delivery - BR-11 measures against it, not the revised date');

-- ---------------------------------------------------------------------------
-- Coherence rules that stop bad states existing at all
-- ---------------------------------------------------------------------------
select dhaaga_test.throws(
    $$update garment set lifecycle = 'delivered' where garment_no = 'ORD-0042-G04' and business_id = '11111111-1111-1111-1111-111111111111'$$,
    'a garment cannot be marked delivered without a delivery time', '23514');

select dhaaga_test.throws(
    $$update sales_order set lifecycle = 'cancelled' where order_no = 'ORD-0042' and business_id = '11111111-1111-1111-1111-111111111111'$$,
    'an order cannot be cancelled without recording when', '23514');

select dhaaga_test.throws(
    $$insert into order_item (business_id, branch_id, order_id, garment_type_id, quantity, unit_price, discount_amount)
      values ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222',
              '0a000000-0000-0000-0000-000000000001', 'dddddddd-0000-0000-0000-000000000001', 1, 600, 900)$$,
    'a discount cannot exceed the line it discounts', '23514');

select dhaaga_test.throws(
    $$insert into order_item (business_id, branch_id, order_id, garment_type_id, quantity, unit_price)
      values ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222',
              '0a000000-0000-0000-0000-000000000001', 'dddddddd-0000-0000-0000-000000000001', 0, 600)$$,
    'a line for zero garments is rejected', '23514');

-- ---------------------------------------------------------------------------
-- Alterations (BR-08)
-- ---------------------------------------------------------------------------
select dhaaga_test.throws(
    $$insert into alteration (business_id, branch_id, garment_id, reason_code, fault_party, chargeable, charge_amount)
      values ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222',
              '0c000000-0000-0000-0000-000000000001', 'too_tight', 'shop', false, 250)$$,
    'a free alteration cannot carry a charge', '23514');

select dhaaga_test.throws(
    $$insert into alteration (business_id, branch_id, garment_id, reason_code, fault_party, chargeable, charge_amount)
      values ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222',
              '0c000000-0000-0000-0000-000000000001', 'customer_changed_mind', 'customer_preference', true, 0)$$,
    'a chargeable alteration must say how much', '23514');

select dhaaga_test.lives(
    $$insert into alteration (business_id, branch_id, garment_id, reason_code, fault_party, chargeable, charge_amount)
      values ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222',
              '0c000000-0000-0000-0000-000000000001', 'sleeve_long', 'shop', false, 0)$$,
    'shop-fault rework is recorded free of charge and counts against quality');

-- ---------------------------------------------------------------------------
-- Date overrides (BR-10)
-- ---------------------------------------------------------------------------
select dhaaga_test.throws(
    $$insert into date_override (business_id, branch_id, entity_type, entity_id, original_date, new_date, user_id, reason_code)
      values ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222', 'garment',
              '0c000000-0000-0000-0000-000000000004', '2026-09-08', '2026-09-08',
              '77777777-0000-0000-0000-000000000001', 'customer_insisted')$$,
    'an override that changes nothing is not an override', '23514');

select dhaaga_test.throws(
    $$insert into date_override (business_id, branch_id, entity_type, entity_id, original_date, new_date, user_id)
      values ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222', 'garment',
              '0c000000-0000-0000-0000-000000000004', '2026-09-08', '2026-09-12',
              '77777777-0000-0000-0000-000000000001')$$,
    'an override without a reason is rejected', '23502');

insert into date_override (business_id, branch_id, entity_type, entity_id, original_date, new_date, user_id, reason_code, reason_text)
values ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222', 'garment',
        '0c000000-0000-0000-0000-000000000004', '2026-09-08', '2026-09-12',
        '77777777-0000-0000-0000-000000000001', 'wedding_date', 'Customer wedding moved');
update garment set promised_date_current = '2026-09-12' where id = '0c000000-0000-0000-0000-000000000004';

select dhaaga_test.eq(
    (select promised_date_original from garment where garment_no = 'ORD-0042-G04' and business_id = '11111111-1111-1111-1111-111111111111'),
    '2026-09-08'::date,
    'moving a promise date never touches the original - the on-time metric cannot be gamed');

-- ---------------------------------------------------------------------------
-- Job cards and tasks
-- ---------------------------------------------------------------------------
insert into workflow_template (id, business_id, garment_type_id, version)
values ('0e000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'dddddddd-0000-0000-0000-000000000001', 1);
insert into workflow_stage (id, business_id, template_id, code, label, sequence_no, standard_minutes)
values ('0f000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', '0e000000-0000-0000-0000-000000000001', 'CUT', 'Cutting', 1, 25),
       ('0f000000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', '0e000000-0000-0000-0000-000000000001', 'STITCH', 'Stitching', 2, 210);

select dhaaga_test.throws(
    $$insert into workflow_stage (business_id, template_id, code, label, sequence_no)
      values ('11111111-1111-1111-1111-111111111111', '0e000000-0000-0000-0000-000000000001', 'PRESS', 'Press', 1)$$,
    'two stages cannot occupy the same position in a route', '23505');

insert into job_card (id, business_id, branch_id, job_no, assigned_to, status)
values ('1a000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222',
        'JC-118', '77777777-0000-0000-0000-000000000001', 'issued'),
       ('1a000000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222',
        'JC-119', '77777777-0000-0000-0000-000000000002', 'open');

insert into job_card_garment (business_id, job_card_id, garment_id)
values ('11111111-1111-1111-1111-111111111111', '1a000000-0000-0000-0000-000000000001', '0c000000-0000-0000-0000-000000000003');

select dhaaga_test.throws(
    $$insert into job_card_garment (business_id, job_card_id, garment_id)
      values ('11111111-1111-1111-1111-111111111111', '1a000000-0000-0000-0000-000000000002',
              '0c000000-0000-0000-0000-000000000003')$$,
    'a garment cannot be on two active job cards at once', '23505');

select dhaaga_test.lives(
    $$update job_card_garment set is_active = false, removed_at = now()
      where garment_id = '0c000000-0000-0000-0000-000000000003';
      insert into job_card_garment (business_id, job_card_id, garment_id)
      values ('11111111-1111-1111-1111-111111111111', '1a000000-0000-0000-0000-000000000002',
              '0c000000-0000-0000-0000-000000000003')$$,
    'a garment moves to another job card once released from the first, and both records survive');

select dhaaga_test.throws(
    $$insert into production_task (business_id, branch_id, job_card_id, garment_id, stage_id, sequence_no, status)
      values ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222',
              '1a000000-0000-0000-0000-000000000001', '0c000000-0000-0000-0000-000000000003',
              '0f000000-0000-0000-0000-000000000001', 1, 'done')$$,
    'a task cannot be complete without a completion time - wages depend on it', '23514');

select dhaaga_test.throws(
    $$insert into production_task (business_id, branch_id, job_card_id, garment_id, stage_id, sequence_no, actual_start, actual_end)
      values ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222',
              '1a000000-0000-0000-0000-000000000001', '0c000000-0000-0000-0000-000000000003',
              '0f000000-0000-0000-0000-000000000001', 1, now(), now() - interval '1 hour')$$,
    'a task cannot finish before it started', '23514');

-- ---------------------------------------------------------------------------
-- Capacity integrity (§6)
-- ---------------------------------------------------------------------------
insert into staff_capacity (business_id, branch_id, user_id, minutes_per_day, effective_from)
values ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222',
        '77777777-0000-0000-0000-000000000001', 480, '2026-01-01');

select dhaaga_test.throws(
    $$insert into staff_capacity (business_id, branch_id, user_id, minutes_per_day, effective_from)
      values ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222',
              '77777777-0000-0000-0000-000000000001', 300, '2026-06-01')$$,
    'one person cannot have two capacity records in force at once - the minute pool must be unambiguous', '23P01');

select dhaaga_test.throws(
    $$insert into staff_capacity (business_id, branch_id, user_id, minutes_per_day, effective_from)
      values ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222',
              '77777777-0000-0000-0000-000000000002', 0, '2026-01-01')$$,
    'a tailor with zero minutes a day is rejected as a data error', '23514');

insert into branch_calendar (business_id, branch_id, weekday, is_working, opens_at, closes_at)
values ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222', 1, true, '10:00', '20:00');

select dhaaga_test.throws(
    $$insert into branch_calendar (business_id, branch_id, weekday, is_working, opens_at, closes_at)
      values ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222', 2, true, '20:00', '10:00')$$,
    'a working day cannot close before it opens', '23514');

select dhaaga_test.throws(
    $$insert into branch_calendar (business_id, branch_id, weekday) values
      ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222', 9)$$,
    'there is no ninth day of the week', '23514');
