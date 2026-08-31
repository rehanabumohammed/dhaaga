-- Cluster 2.2 behaviour: configuration, localisation and tax integrity.
-- These are the constraints AP-1, BR-15, BR-18 and BR-22 rest on. If any of
-- them can be violated, "the rule in force at the time" stops being knowable.

insert into business (id, legal_name) values ('11111111-1111-1111-1111-111111111111', 'Test Tailors');
insert into branch (id, business_id, code, name)
values ('22222222-2222-2222-2222-222222222222', '11111111-1111-1111-1111-111111111111', 'BR1', 'Main');

-- ---------------------------------------------------------------------------
-- Localisation (decision 3)
-- ---------------------------------------------------------------------------
insert into locale (business_id, code, name, native_name, is_default)
values ('11111111-1111-1111-1111-111111111111', 'en-IN', 'English', 'English', true);

select dhaaga_test.throws(
    $$insert into locale (business_id, code, name, is_default)
      values ('11111111-1111-1111-1111-111111111111', 'hi-IN', 'Hindi', true)$$,
    'a business cannot have two default locales', '23505');

select dhaaga_test.lives(
    $$insert into locale (business_id, code, name, native_name, direction)
      values ('11111111-1111-1111-1111-111111111111', 'hi-IN', 'Hindi', 'हिन्दी', 'ltr')$$,
    'a second, non-default locale is allowed - Hindi is present from P0');

select dhaaga_test.lives(
    $$insert into locale (business_id, code, name, native_name, direction)
      values ('11111111-1111-1111-1111-111111111111', 'ur-IN', 'Urdu', 'اردو', 'rtl')$$,
    'a right-to-left locale is representable without a schema change');

select dhaaga_test.throws(
    $$insert into locale (business_id, code, name, direction)
      values ('11111111-1111-1111-1111-111111111111', 'xx-XX', 'Nonsense', 'sideways')$$,
    'an invalid text direction is rejected', '23514');

-- ---------------------------------------------------------------------------
-- Configuration versioning and effective dating (BR-18)
-- ---------------------------------------------------------------------------
insert into config_setting (id, business_id, key, category, value_type, default_value, required_permission, is_effective_dated)
values ('33333333-3333-3333-3333-333333333333', '11111111-1111-1111-1111-111111111111',
        'production.rework_reserve_percent', 'production', 'decimal', '12'::jsonb, 'config.production.manage', true);

insert into config_version (business_id, setting_id, value, effective_from, effective_to)
values ('11111111-1111-1111-1111-111111111111', '33333333-3333-3333-3333-333333333333',
        '12'::jsonb, '2026-01-01', '2026-06-01');

select dhaaga_test.throws(
    $$insert into config_version (business_id, setting_id, value, effective_from, effective_to)
      values ('11111111-1111-1111-1111-111111111111', '33333333-3333-3333-3333-333333333333',
              '15'::jsonb, '2026-05-01', '2026-09-01')$$,
    'two values cannot apply to one setting at the same moment', '23P01');

select dhaaga_test.lives(
    $$insert into config_version (business_id, setting_id, value, effective_from)
      values ('11111111-1111-1111-1111-111111111111', '33333333-3333-3333-3333-333333333333',
              '15'::jsonb, '2026-06-01')$$,
    'a value taking effect when the previous one ends is allowed');

select dhaaga_test.throws(
    $$insert into config_version (business_id, setting_id, value, effective_from, effective_to)
      values ('11111111-1111-1111-1111-111111111111', '33333333-3333-3333-3333-333333333333',
              '9'::jsonb, '2026-03-01', '2026-02-01')$$,
    'a validity window cannot end before it starts', '23514');

select dhaaga_test.throws(
    $$insert into config_setting (business_id, key, category, value_type, default_value, required_permission)
      values ('11111111-1111-1111-1111-111111111111', 'bad.type', 'misc', 'flibble', '1'::jsonb, 'x')$$,
    'an unknown value type is rejected', '23514');

-- ---------------------------------------------------------------------------
-- Tax rates in force (BR-15)
-- ---------------------------------------------------------------------------
insert into tax_code (id, business_id, code, kind, hsn_sac, description)
values ('44444444-4444-4444-4444-444444444444', '11111111-1111-1111-1111-111111111111',
        'STITCHING', 'service', '998821', 'Tailoring service - rate to be confirmed by CA (BR-22)');

insert into tax_rate (id, business_id, tax_code_id, total_percent, effective_from, effective_to)
values ('55555555-5555-5555-5555-555555555555', '11111111-1111-1111-1111-111111111111',
        '44444444-4444-4444-4444-444444444444', 5, '2026-04-01', '2027-04-01');

select dhaaga_test.throws(
    $$insert into tax_rate (business_id, tax_code_id, total_percent, effective_from, effective_to)
      values ('11111111-1111-1111-1111-111111111111', '44444444-4444-4444-4444-444444444444',
              12, '2026-10-01', '2027-10-01')$$,
    'one tax code cannot have two rates in force at the same time', '23P01');

select dhaaga_test.lives(
    $$insert into tax_rate (business_id, tax_code_id, total_percent, effective_from)
      values ('11111111-1111-1111-1111-111111111111', '44444444-4444-4444-4444-444444444444',
              12, '2027-04-01')$$,
    'a future rate change is recorded alongside the current rate');

select dhaaga_test.eq(
    (select total_percent from tax_rate
     where tax_code_id = '44444444-4444-4444-4444-444444444444'
       and daterange(effective_from, effective_to) @> date '2026-08-26')::numeric,
    5::numeric,
    'the rate in force on a given date is unambiguous - the basis of BR-15');

select dhaaga_test.throws(
    $$insert into tax_rate (business_id, tax_code_id, total_percent, effective_from)
      values ('11111111-1111-1111-1111-111111111111', '44444444-4444-4444-4444-444444444444', 250, '2030-01-01')$$,
    'an impossible tax percentage is rejected', '23514');

insert into tax_rate_component (business_id, tax_rate_id, component, percent)
values ('11111111-1111-1111-1111-111111111111', '55555555-5555-5555-5555-555555555555', 'CGST', 2.5),
       ('11111111-1111-1111-1111-111111111111', '55555555-5555-5555-5555-555555555555', 'SGST', 2.5);

select dhaaga_test.eq(
    (select sum(percent) from tax_rate_component where tax_rate_id = '55555555-5555-5555-5555-555555555555')::numeric,
    5::numeric,
    'a rate breaks into components that sum back to the total');

select dhaaga_test.throws(
    $$insert into tax_rate_component (business_id, tax_rate_id, component, percent)
      values ('11111111-1111-1111-1111-111111111111', '55555555-5555-5555-5555-555555555555', 'CGST', 9)$$,
    'the same component cannot be added twice to one rate', '23505');

-- ---------------------------------------------------------------------------
-- Reason codes are data, not an enum in code (AP-1)
-- ---------------------------------------------------------------------------
insert into reason_code (business_id, domain, code, label, requires_text)
values ('11111111-1111-1111-1111-111111111111', 'date_override', 'customer_insisted', 'Customer insisted', false),
       ('11111111-1111-1111-1111-111111111111', 'date_override', 'wedding_date', 'Wedding or event date', false),
       ('11111111-1111-1111-1111-111111111111', 'date_override', 'other', 'Other', true);

select dhaaga_test.eq(
    (select count(*)::int from reason_code where domain = 'date_override' and business_id = '11111111-1111-1111-1111-111111111111'), 3,
    'the owner controls the reason list for a domain without a release');

select dhaaga_test.throws(
    $$insert into reason_code (business_id, domain, code, label)
      values ('11111111-1111-1111-1111-111111111111', 'made_up_domain', 'x', 'X')$$,
    'reason codes can only attach to domains the application knows about', '23514');

-- ---------------------------------------------------------------------------
-- The CA sign-off (BR-22)
-- ---------------------------------------------------------------------------
insert into validation_signoff (business_id, domain, validated_by_name, firm, validated_on, config_hash)
values ('11111111-1111-1111-1111-111111111111', 'tax', 'CA to be appointed', 'Firm', '2026-09-01', 'hash-abc');

select dhaaga_test.throws(
    $$insert into validation_signoff (business_id, domain, validated_by_name, validated_on, config_hash)
      values ('11111111-1111-1111-1111-111111111111', 'tax', 'Someone else', '2026-10-01', 'hash-def')$$,
    'only one sign-off can be current for a domain at a time', '23505');

select dhaaga_test.lives(
    $$update validation_signoff set is_current = false, superseded_at = now(),
             superseded_reason = 'rate changed' where domain = 'tax';
      insert into validation_signoff (business_id, domain, validated_by_name, validated_on, config_hash)
      values ('11111111-1111-1111-1111-111111111111', 'tax', 'Someone else', '2026-10-01', 'hash-def')$$,
    'superseding the previous sign-off allows a new one - history is kept, not replaced');
