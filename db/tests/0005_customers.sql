-- Cluster 2.3 behaviour: identity, households, and the measurement guarantee.
-- The assertions here are the ones the v0.1 design would have failed.

insert into business (id, legal_name) values ('11111111-1111-1111-1111-111111111111', 'Test Tailors');
insert into branch (id, business_id, code, name)
values ('22222222-2222-2222-2222-222222222222', '11111111-1111-1111-1111-111111111111', 'BR1', 'Main');

-- ---------------------------------------------------------------------------
-- The Khan family: one phone number, four people
-- ---------------------------------------------------------------------------
insert into household (id, business_id, name)
values ('aaaaaaaa-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Khan Family');

insert into customer (id, business_id, customer_code, display_name, name_normalized, gender)
values ('cccccccc-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'C-000001', 'Imran Khan',  'imran khan',  'male'),
       ('cccccccc-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'C-000002', 'Ayesha Khan', 'ayesha khan', 'female'),
       ('cccccccc-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111', 'C-000003', 'Bilal Khan',  'bilal khan',  'male'),
       ('cccccccc-0000-0000-0000-000000000004', '11111111-1111-1111-1111-111111111111', 'C-000004', 'Sana Khan',   'sana khan',   'female');

insert into household_member (business_id, household_id, customer_id, relation, is_primary_contact)
values ('11111111-1111-1111-1111-111111111111', 'aaaaaaaa-0000-0000-0000-000000000001', 'cccccccc-0000-0000-0000-000000000001', 'head', true),
       ('11111111-1111-1111-1111-111111111111', 'aaaaaaaa-0000-0000-0000-000000000001', 'cccccccc-0000-0000-0000-000000000002', 'spouse', false),
       ('11111111-1111-1111-1111-111111111111', 'aaaaaaaa-0000-0000-0000-000000000001', 'cccccccc-0000-0000-0000-000000000003', 'son', false),
       ('11111111-1111-1111-1111-111111111111', 'aaaaaaaa-0000-0000-0000-000000000001', 'cccccccc-0000-0000-0000-000000000004', 'daughter', false);

select dhaaga_test.eq(
    (select count(*)::int from household_member where household_id = 'aaaaaaaa-0000-0000-0000-000000000001'),
    4, 'a household holds four members, each a full customer');

-- The whole point of the v0.2 identity change: one number, several people.
insert into customer_contact (business_id, customer_id, kind, value_raw, value_e164, is_primary)
values ('11111111-1111-1111-1111-111111111111', 'cccccccc-0000-0000-0000-000000000001', 'mobile', '98765 43210', '+919876543210', true);

select dhaaga_test.lives(
    $$insert into customer_contact (business_id, customer_id, kind, value_raw, value_e164, label)
      values ('11111111-1111-1111-1111-111111111111', 'cccccccc-0000-0000-0000-000000000002',
              'mobile', '98765 43210', '+919876543210', 'husband''s phone')$$,
    'two family members can share one phone number - it is not an identity');

select dhaaga_test.lives(
    $$insert into customer_contact (business_id, customer_id, kind, value_raw, value_e164)
      values ('11111111-1111-1111-1111-111111111111', 'cccccccc-0000-0000-0000-000000000001',
              'whatsapp', '99887 76655', '+919988776655')$$,
    'one person can hold several numbers');

select dhaaga_test.throws(
    $$insert into customer_contact (business_id, customer_id, kind, value_raw, is_primary)
      values ('11111111-1111-1111-1111-111111111111', 'cccccccc-0000-0000-0000-000000000001', 'mobile', '111', true)$$,
    'a customer cannot have two primary contacts', '23505');

-- A customer with no contact at all is completely normal.
select dhaaga_test.lives(
    $$insert into customer (business_id, customer_code, display_name, name_normalized)
      values ('11111111-1111-1111-1111-111111111111', 'C-000005', 'Walk-in, no phone', 'walk-in no phone')$$,
    'a customer with no phone number at all is valid');

select dhaaga_test.throws(
    $$insert into customer_contact (business_id, kind, value_raw) values ('11111111-1111-1111-1111-111111111111', 'mobile', '5')$$,
    'a contact must belong to exactly one customer or household', '23514');

-- V1 rule: one household per customer, enforced by an index that can simply be
-- dropped if shared households are ever needed.
select dhaaga_test.throws(
    $$insert into household (id, business_id, name)
      values ('aaaaaaaa-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'Second Family');
      insert into household_member (business_id, household_id, customer_id, relation)
      values ('11111111-1111-1111-1111-111111111111', 'aaaaaaaa-0000-0000-0000-000000000002',
              'cccccccc-0000-0000-0000-000000000001', 'other')$$,
    'in V1 a customer belongs to one household', '23505');

-- ---------------------------------------------------------------------------
-- Merge: recorded, redirecting, coherent
-- ---------------------------------------------------------------------------
select dhaaga_test.throws(
    $$update customer set status = 'merged' where id = 'cccccccc-0000-0000-0000-000000000003'$$,
    'a customer cannot be marked merged without saying what it merged into', '23514');

select dhaaga_test.throws(
    $$update customer set status = 'merged', merged_into_id = id where id = 'cccccccc-0000-0000-0000-000000000003'$$,
    'a customer cannot be merged into itself', '23514');

update customer set status = 'merged', merged_into_id = 'cccccccc-0000-0000-0000-000000000001'
where id = 'cccccccc-0000-0000-0000-000000000003';

insert into customer_merge (business_id, surviving_id, merged_id, moved_rows, field_choices)
values ('11111111-1111-1111-1111-111111111111', 'cccccccc-0000-0000-0000-000000000001',
        'cccccccc-0000-0000-0000-000000000003',
        '{"customer_contact": 2, "measurement_profile": 1}'::jsonb,
        '{"display_name": "surviving"}'::jsonb);

select dhaaga_test.eq(
    (select count(*)::int from customer where id = 'cccccccc-0000-0000-0000-000000000003'),
    1, 'the merged record survives and is not deleted (BR-12)');

select dhaaga_test.eq(
    (select merged_into_id from customer where id = 'cccccccc-0000-0000-0000-000000000003'),
    'cccccccc-0000-0000-0000-000000000001'::uuid,
    'the merged record redirects, so old job cards and invoices never break');

-- Duplicate candidates are ordered pairs, so the same pair cannot be queued twice.
select dhaaga_test.throws(
    $$insert into duplicate_candidate (business_id, customer_a_id, customer_b_id, score)
      values ('11111111-1111-1111-1111-111111111111',
              'cccccccc-0000-0000-0000-000000000002', 'cccccccc-0000-0000-0000-000000000001', 0.9)$$,
    'a duplicate pair must be stored in a canonical order', '23514');

insert into duplicate_candidate (business_id, customer_a_id, customer_b_id, score, reasons)
values ('11111111-1111-1111-1111-111111111111',
        'cccccccc-0000-0000-0000-000000000001', 'cccccccc-0000-0000-0000-000000000002',
        0.900, '{"phone_exact": 0.6, "name_similarity": 0.3}'::jsonb);

select dhaaga_test.throws(
    $$insert into duplicate_candidate (business_id, customer_a_id, customer_b_id, score)
      values ('11111111-1111-1111-1111-111111111111',
              'cccccccc-0000-0000-0000-000000000001', 'cccccccc-0000-0000-0000-000000000002', 0.95)$$,
    'the same pair cannot sit in the review queue twice', '23505');

select dhaaga_test.throws(
    $$insert into duplicate_candidate (business_id, customer_a_id, customer_b_id, score)
      values ('11111111-1111-1111-1111-111111111111',
              'cccccccc-0000-0000-0000-000000000002', 'cccccccc-0000-0000-0000-000000000004', 1.5)$$,
    'a duplicate score outside 0..1 is rejected', '23514');

-- ---------------------------------------------------------------------------
-- Measurements: the BR-01 guarantee
-- ---------------------------------------------------------------------------
insert into garment_type (id, business_id, code, name, requires_trial)
values ('dddddddd-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'SHIRT', 'Shirt', false);

insert into measurement_template (id, business_id, garment_type_id, version)
values ('eeeeeeee-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
        'dddddddd-0000-0000-0000-000000000001', 1);

select dhaaga_test.throws(
    $$insert into measurement_template (business_id, garment_type_id, version, is_current)
      values ('11111111-1111-1111-1111-111111111111', 'dddddddd-0000-0000-0000-000000000001', 2, true)$$,
    'a garment type has exactly one current template version', '23505');

insert into template_field (business_id, template_id, code, label, unit, min_value, max_value, display_order)
values ('11111111-1111-1111-1111-111111111111', 'eeeeeeee-0000-0000-0000-000000000001', 'chest', 'Chest', 'inch', 20, 70, 10),
       ('11111111-1111-1111-1111-111111111111', 'eeeeeeee-0000-0000-0000-000000000001', 'length', 'Length', 'inch', 20, 60, 20);

select dhaaga_test.throws(
    $$insert into template_field (business_id, template_id, code, label, min_value, max_value)
      values ('11111111-1111-1111-1111-111111111111', 'eeeeeeee-0000-0000-0000-000000000001', 'waist', 'Waist', 50, 20)$$,
    'a sanity range cannot end below where it starts', '23514');

insert into measurement_profile (id, business_id, customer_id, garment_type_id, name)
values ('ffffffff-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
        'cccccccc-0000-0000-0000-000000000001', 'dddddddd-0000-0000-0000-000000000001', 'regular');

insert into measurement_revision (id, business_id, profile_id, template_id, revision_no, source, values_cache)
values ('99999999-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
        'ffffffff-0000-0000-0000-000000000001', 'eeeeeeee-0000-0000-0000-000000000001', 1,
        'measured_in_store', '{"chest": 40.0, "length": 29.5}'::jsonb);

insert into measurement_value (business_id, revision_id, field_code, value_numeric)
values ('11111111-1111-1111-1111-111111111111', '99999999-0000-0000-0000-000000000001', 'chest', 40.0),
       ('11111111-1111-1111-1111-111111111111', '99999999-0000-0000-0000-000000000001', 'length', 29.5);

-- Freeze a snapshot, as order confirmation would.
insert into measurement_snapshot (id, business_id, source_revision_id, template_id, template_version, unit, source, values_frozen)
values ('88888888-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
        '99999999-0000-0000-0000-000000000001', 'eeeeeeee-0000-0000-0000-000000000001', 1,
        'inch', 'measured_in_store', '{"chest": 40.0, "length": 29.5}'::jsonb);

-- The customer gains half an inch. A new revision supersedes the old one.
update measurement_revision set is_current = false where id = '99999999-0000-0000-0000-000000000001';
insert into measurement_revision (business_id, profile_id, template_id, revision_no, source, values_cache)
values ('11111111-1111-1111-1111-111111111111', 'ffffffff-0000-0000-0000-000000000001',
        'eeeeeeee-0000-0000-0000-000000000001', 2, 'measured_in_store',
        '{"chest": 40.5, "length": 29.5}'::jsonb);

select dhaaga_test.eq(
    (select (values_frozen ->> 'chest')::numeric from measurement_snapshot where id = '88888888-0000-0000-0000-000000000001'),
    40.0::numeric,
    'BR-01: a later measurement change does not touch the garment already frozen');

select dhaaga_test.eq(
    (select (values_cache ->> 'chest')::numeric from measurement_revision where profile_id = 'ffffffff-0000-0000-0000-000000000001' and is_current),
    40.5::numeric,
    'the current profile shows the new measurement');

select dhaaga_test.eq(
    (select count(*)::int from measurement_revision where profile_id = 'ffffffff-0000-0000-0000-000000000001'),
    2, 'revisions are append-only - the history stays browsable');

-- Even deleting the source revision cannot change what the garment was cut to.
update measurement_revision set deleted_at = now() where id = '99999999-0000-0000-0000-000000000001';
select dhaaga_test.eq(
    (select (values_frozen ->> 'chest')::numeric from measurement_snapshot where id = '88888888-0000-0000-0000-000000000001'),
    40.0::numeric,
    'the snapshot survives removal of the revision it came from - no live link back');

select dhaaga_test.throws(
    $$insert into measurement_snapshot (business_id, template_id, template_version, unit, source, values_frozen)
      values ('11111111-1111-1111-1111-111111111111', 'eeeeeeee-0000-0000-0000-000000000001', 1, 'inch', 'measured_in_store', '{}'::jsonb)$$,
    'an empty snapshot is rejected - a garment cannot be cut to nothing', '23514');

select dhaaga_test.throws(
    $$insert into measurement_revision (business_id, profile_id, template_id, revision_no, source)
      values ('11111111-1111-1111-1111-111111111111', 'ffffffff-0000-0000-0000-000000000001',
              'eeeeeeee-0000-0000-0000-000000000001', 3, 'guessed')$$,
    'an unknown measurement source is rejected', '23514');

select dhaaga_test.throws(
    $$insert into measurement_value (business_id, revision_id, field_code)
      values ('11111111-1111-1111-1111-111111111111', '99999999-0000-0000-0000-000000000001', 'sleeve')$$,
    'a measurement value must actually hold a value', '23514');
