-- WP-4: the audit framework does what BR-13 requires.
--
-- The assertions that matter most are the two that are easy to skip: that a
-- change made OUTSIDE the application is recorded just as faithfully, and that
-- an audit row cannot be altered by anyone at all, including the table owner.

insert into business (id, legal_name) values ('11111111-1111-1111-1111-111111111111', 'Test Tailors');
insert into branch (id, business_id, code, name)
values ('22222222-2222-2222-2222-222222222222', '11111111-1111-1111-1111-111111111111', 'BR1', 'Main');
insert into app_user (id, business_id, full_name)
values ('77777777-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Counter staff');
insert into customer (id, business_id, display_name)
values ('cccccccc-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Imran Khan');
insert into garment_type (id, business_id, code, name)
values ('dddddddd-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'SHIRT', 'Shirt');
insert into device (id, business_id, label, platform)
values ('88888888-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Counter tablet', 'android');

-- ---------------------------------------------------------------------------
-- A change made with no application context at all
-- ---------------------------------------------------------------------------
-- This is the console case: someone connects with psql and edits a row. The
-- application never sees it. The audit trail must still.
select set_config('app.actor_id', '', true);
select set_config('request.jwt.claims', '', true);

update customer set display_name = 'Imran Khan (console edit)'
where id = 'cccccccc-0000-0000-0000-000000000001';

select dhaaga_test.eq(
    (select count(*)::int from audit_event
     where entity_type = 'customer' and entity_id = 'cccccccc-0000-0000-0000-000000000001'
       and action = 'update'),
    1, 'a change made outside the application is recorded');

select dhaaga_test.eq(
    (select source from audit_event where entity_type = 'customer' and action = 'update'),
    'console',
    'and is labelled as out-of-band rather than attributed to somebody who was not there');

select dhaaga_test.eq(
    (select actor_user_id from audit_event where entity_type = 'customer' and action = 'update'),
    null::uuid, 'with no actor invented for it');

select dhaaga_test.eq(
    (select before_data ->> 'display_name' from audit_event
     where entity_type = 'customer' and action = 'update'),
    'Imran Khan', 'the before value is captured');

select dhaaga_test.eq(
    (select after_data ->> 'display_name' from audit_event
     where entity_type = 'customer' and action = 'update'),
    'Imran Khan (console edit)', 'and the after value');

select dhaaga_test.eq(
    (select changed_fields from audit_event where entity_type = 'customer' and action = 'update'),
    array['display_name']::text[],
    'and exactly which field moved - not the housekeeping columns that change on every write');

-- ---------------------------------------------------------------------------
-- A change made through the application, with an actor and a device
-- ---------------------------------------------------------------------------
select app.set_context(
    actor_id    => '77777777-0000-0000-0000-000000000001',
    device_id   => '88888888-0000-0000-0000-000000000001',
    reason_code => 'wrong_spelling',
    reason_text => 'Customer corrected it at the counter');

update customer set display_name = 'Imraan Khan'
where id = 'cccccccc-0000-0000-0000-000000000001';

select dhaaga_test.eq(
    (select actor_user_id from audit_event
     where entity_type = 'customer' and after_data ->> 'display_name' = 'Imraan Khan'),
    '77777777-0000-0000-0000-000000000001'::uuid,
    'an in-app change is attributed to the person who made it');

select dhaaga_test.eq(
    (select device_id from audit_event
     where entity_type = 'customer' and after_data ->> 'display_name' = 'Imraan Khan'),
    '88888888-0000-0000-0000-000000000001'::uuid,
    'and to the device it came from - offline actions need this (§5.4)');

select dhaaga_test.eq(
    (select reason_code from audit_event
     where entity_type = 'customer' and after_data ->> 'display_name' = 'Imraan Khan'),
    'wrong_spelling', 'with the reason given');

select dhaaga_test.eq(
    (select source from audit_event
     where entity_type = 'customer' and after_data ->> 'display_name' = 'Imraan Khan'),
    'system', 'and the source recorded');

-- An unknown device degrades attribution; it never blocks the write, because a
-- customer's order must not fail over a diagnostic column.
select app.set_context(
    actor_id  => '77777777-0000-0000-0000-000000000001',
    device_id => 'deadbeef-0000-0000-0000-00000000ffff');

select dhaaga_test.lives(
    $$update customer set display_name = 'Imraan Khan Sr'
      where id = 'cccccccc-0000-0000-0000-000000000001'$$,
    'a stale or unknown device id does not fail the write behind it');

select dhaaga_test.eq(
    (select device_id from audit_event
     where entity_type = 'customer' and after_data ->> 'display_name' = 'Imraan Khan Sr'),
    null::uuid,
    'the row is still recorded, with attribution left empty rather than invented');

-- ---------------------------------------------------------------------------
-- Inserts and deletes
-- ---------------------------------------------------------------------------
select app.set_context(actor_id => '77777777-0000-0000-0000-000000000001');

insert into sales_order (id, business_id, branch_id, order_no, customer_id)
values ('0a000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
        '22222222-2222-2222-2222-222222222222', 'ORD-0001', 'cccccccc-0000-0000-0000-000000000001');

select dhaaga_test.eq(
    (select action from audit_event where entity_type = 'sales_order'),
    'insert', 'creating an order is audited');

select dhaaga_test.eq(
    (select before_data from audit_event where entity_type = 'sales_order'),
    null::jsonb, 'an insert has no before state');

select dhaaga_test.eq(
    (select after_data ->> 'order_no' from audit_event where entity_type = 'sales_order'),
    'ORD-0001', 'and its after state carries the row');

-- ---------------------------------------------------------------------------
-- A statement that changes nothing meaningful writes nothing
-- ---------------------------------------------------------------------------
-- Without this the log fills with rows in which only updated_at moved, and a
-- log nobody can read is a log nobody reads.
update sales_order set notes = null where order_no = 'ORD-0001';

select dhaaga_test.eq(
    (select count(*)::int from audit_event where entity_type = 'sales_order'),
    1, 'a no-op update produces no audit row');

update sales_order set notes = 'Urgent' where order_no = 'ORD-0001';
select dhaaga_test.eq(
    (select count(*)::int from audit_event where entity_type = 'sales_order'),
    2, 'but a real change does');

-- ---------------------------------------------------------------------------
-- Mandatory reasons (AP-1: the list is data)
-- ---------------------------------------------------------------------------
insert into audit_reason_requirement (business_id, entity_type, action, column_name, note)
values ('11111111-1111-1111-1111-111111111111', 'order_item', 'update', 'unit_price',
        'A price override must say why (BR-13)');

insert into order_item (id, business_id, branch_id, order_id, garment_type_id, quantity, unit_price)
values ('0b000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
        '22222222-2222-2222-2222-222222222222', '0a000000-0000-0000-0000-000000000001',
        'dddddddd-0000-0000-0000-000000000001', 1, 600);

select app.set_context(actor_id => '77777777-0000-0000-0000-000000000001');

select dhaaga_test.throws(
    $$update order_item set unit_price = 450 where id = '0b000000-0000-0000-0000-000000000001'$$,
    'changing a price without a reason is refused', '23514');

select dhaaga_test.lives(
    $$select app.set_context(actor_id => '77777777-0000-0000-0000-000000000001',
                             reason_code => 'regular_customer');
      update order_item set unit_price = 450 where id = '0b000000-0000-0000-0000-000000000001'$$,
    'the same change with a reason is allowed');

-- The requirement is narrowed to one column: editing a note is not a price
-- override and must not demand a justification.
select app.set_context(actor_id => '77777777-0000-0000-0000-000000000001');
select dhaaga_test.lives(
    $$update order_item set notes = 'Blue thread' where id = '0b000000-0000-0000-0000-000000000001'$$,
    'and an unrelated edit to the same row needs no reason');

-- ---------------------------------------------------------------------------
-- The trail cannot be rewritten - by anyone (BR-13)
-- ---------------------------------------------------------------------------
-- These run as the table owner. Policies and grants do not restrain an owner,
-- so if this passes only because of them, it proves nothing. It passes because
-- of a trigger.
select dhaaga_test.throws(
    $$update audit_event set reason_code = 'covered up'
      where entity_type = 'customer'$$,
    'an audit row cannot be modified, even by the table owner', '42501');

select dhaaga_test.throws(
    $$delete from audit_event where entity_type = 'customer'$$,
    'nor deleted', '42501');

select dhaaga_test.throws(
    $$update audit_event set deleted_at = now() where entity_type = 'customer'$$,
    'nor soft-deleted out of sight', '42501');

-- ---------------------------------------------------------------------------
-- Coverage: the tables BR-13 names are all watched
-- ---------------------------------------------------------------------------
select dhaaga_test.eq(
    coalesce((select string_agg(t, ', ' order by t) from unnest(array[
        'payment','invoice','credit_note','sales_order','order_item','garment',
        'date_override','alteration','wage_entry','wage_payout','stock_movement',
        'customer_material','app_user','role_permission','user_branch_role',
        'config_setting','tax_rate','customer','measurement_revision',
        'measurement_snapshot','journal_entry','delivery_note','number_void'
    ]) t
    where not exists (
        select 1 from pg_trigger g
        where g.tgrelid = ('public.' || t)::regclass
          and g.tgname = 'zz_audit_' || t and not g.tgisinternal)), ''),
    '', 'every event BR-13 names is captured by a trigger on its table');

select dhaaga_test.eq(
    (select count(*)::int from pg_trigger g
     where g.tgrelid = 'audit_event'::regclass and g.tgname = 'zz_audit_audit_event'),
    0, 'the audit table is not audited by itself');
