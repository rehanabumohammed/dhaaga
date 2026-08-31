-- Cluster 2.1 behaviour: the tenancy spine actually behaves as designed.

-- A business, a branch and a user to work with.
insert into business (id, legal_name, trade_name)
values ('11111111-1111-1111-1111-111111111111', 'Test Tailors Pvt Ltd', 'Test Tailors');

select dhaaga_test.eq(
    (select business_id from business where id = '11111111-1111-1111-1111-111111111111'),
    '11111111-1111-1111-1111-111111111111'::uuid,
    'business.business_id mirrors its own id so the tenant predicate is uniform');

insert into branch (id, business_id, code, name)
values ('22222222-2222-2222-2222-222222222222', '11111111-1111-1111-1111-111111111111', 'BR1', 'Main');

-- ---------------------------------------------------------------------------
-- Row maintenance
-- ---------------------------------------------------------------------------
select dhaaga_test.eq((select row_version from branch where code = 'BR1' and business_id = '11111111-1111-1111-1111-111111111111'), 1,
    'a new row starts at row_version 1');

update branch set name = 'Main Branch' where code = 'BR1';
select dhaaga_test.eq((select row_version from branch where code = 'BR1' and business_id = '11111111-1111-1111-1111-111111111111'), 2,
    'an update increments row_version');

select dhaaga_test.ok(
    (select updated_at >= created_at from branch where code = 'BR1' and business_id = '11111111-1111-1111-1111-111111111111'),
    'updated_at moves forward on update');

-- created_at is immutable: a client that sends a different created_at cannot
-- rewrite when a record came into existence.
update branch set created_at = '2000-01-01' where code = 'BR1' and business_id = '11111111-1111-1111-1111-111111111111';
select dhaaga_test.ok(
    (select created_at > '2020-01-01'::timestamptz from branch where code = 'BR1' and business_id = '11111111-1111-1111-1111-111111111111'),
    'created_at cannot be overwritten by an update');

-- ---------------------------------------------------------------------------
-- Uniqueness is scoped to the business and tolerates soft deletion
-- ---------------------------------------------------------------------------
select dhaaga_test.throws(
    $$insert into branch (business_id, code, name)
      values ('11111111-1111-1111-1111-111111111111', 'BR1', 'Duplicate')$$,
    'a second live branch cannot reuse a branch code', '23505');

update branch set deleted_at = now() where code = 'BR1' and business_id = '11111111-1111-1111-1111-111111111111';
select dhaaga_test.lives(
    $$insert into branch (business_id, code, name)
      values ('11111111-1111-1111-1111-111111111111', 'BR1', 'Reopened')$$,
    'a soft-deleted branch code becomes available again');

-- ---------------------------------------------------------------------------
-- Number leases must never overlap (§5.3)
-- ---------------------------------------------------------------------------
insert into device (id, business_id, label, platform)
values ('44444444-4444-4444-4444-444444444444', '11111111-1111-1111-1111-111111111111', 'Counter tablet', 'android'),
       ('55555555-5555-5555-5555-555555555555', '11111111-1111-1111-1111-111111111111', 'Manager phone', 'android');

insert into number_series (id, business_id, branch_id, doc_type, financial_year, prefix, is_offline_leasable)
values ('33333333-3333-3333-3333-333333333333', '11111111-1111-1111-1111-111111111111',
        (select id from branch where name = 'Reopened' and business_id = '11111111-1111-1111-1111-111111111111'), 'order_token', '2026-27', 'BR1-', true);

insert into number_lease (business_id, branch_id, series_id, device_id, range_start, range_end, next_value, expires_at)
values ('11111111-1111-1111-1111-111111111111', (select id from branch where name = 'Reopened' and business_id = '11111111-1111-1111-1111-111111111111'),
        '33333333-3333-3333-3333-333333333333', '44444444-4444-4444-4444-444444444444',
        1, 100, 1, now() + interval '7 days');

select dhaaga_test.throws(
    $$insert into number_lease (business_id, branch_id, series_id, device_id, range_start, range_end, next_value, expires_at)
      values ('11111111-1111-1111-1111-111111111111', (select id from branch where name = 'Reopened' and business_id = '11111111-1111-1111-1111-111111111111'),
              '33333333-3333-3333-3333-333333333333', '55555555-5555-5555-5555-555555555555',
              50, 150, 50, now() + interval '7 days')$$,
    'two devices cannot hold overlapping number ranges from one series', '23P01');

select dhaaga_test.lives(
    $$insert into number_lease (business_id, branch_id, series_id, device_id, range_start, range_end, next_value, expires_at)
      values ('11111111-1111-1111-1111-111111111111', (select id from branch where name = 'Reopened' and business_id = '11111111-1111-1111-1111-111111111111'),
              '33333333-3333-3333-3333-333333333333', '55555555-5555-5555-5555-555555555555',
              101, 200, 101, now() + interval '7 days')$$,
    'a non-overlapping range for a second device is allowed');

select dhaaga_test.throws(
    $$insert into number_lease (business_id, branch_id, series_id, device_id, range_start, range_end, next_value, expires_at)
      values ('11111111-1111-1111-1111-111111111111', (select id from branch where name = 'Reopened' and business_id = '11111111-1111-1111-1111-111111111111'),
              '33333333-3333-3333-3333-333333333333', '44444444-4444-4444-4444-444444444444',
              300, 250, 300, now() + interval '7 days')$$,
    'a lease with an inverted range is rejected', '23514');

-- Every voided number is unique within its series: a gap is explained once.
insert into number_void (business_id, branch_id, series_id, value, reason_code)
values ('11111111-1111-1111-1111-111111111111', (select id from branch where name = 'Reopened' and business_id = '11111111-1111-1111-1111-111111111111'),
        '33333333-3333-3333-3333-333333333333', 42, 'lease_expired');

select dhaaga_test.throws(
    $$insert into number_void (business_id, branch_id, series_id, value, reason_code)
      values ('11111111-1111-1111-1111-111111111111', (select id from branch where name = 'Reopened' and business_id = '11111111-1111-1111-1111-111111111111'),
              '33333333-3333-3333-3333-333333333333', 42, 'lease_expired')$$,
    'the same number cannot be voided twice in one series', '23505');

-- ---------------------------------------------------------------------------
-- Guard rails on enumerated state
-- ---------------------------------------------------------------------------
select dhaaga_test.throws(
    $$insert into number_series (business_id, branch_id, doc_type, financial_year)
      values ('11111111-1111-1111-1111-111111111111', (select id from branch where name = 'Reopened' and business_id = '11111111-1111-1111-1111-111111111111'),
              'not_a_document_type', '2026-27')$$,
    'an unknown document type is rejected', '23514');

select dhaaga_test.throws(
    $$insert into business (legal_name, financial_year_start_month) values ('Bad FY', 13)$$,
    'a financial year cannot start in month 13', '23514');
