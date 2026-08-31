-- WP-6 · Configuration resolvers.
--
-- The definition of done from Appendix B: "a setting changes only with the
-- right permission, its history is queryable, a past date resolves the value
-- in force then, and changing a validated setting invalidates the CA sign-off."
--
-- Four of the assertions below are regression tests in the literal sense: they
-- were written against defects reproduced in the first draft of migration 0015
-- and they failed before the migration was corrected. They are marked REGRESSION.

-- ===========================================================================
-- Fixtures
-- ===========================================================================
-- Two businesses. Business A has a user with the config.manage permission and
-- a user with none, so "permitted" and "unpermitted" are two real callers
-- rather than one caller and a mocked check.
insert into business (id, legal_name) values
 ('cccc0015-0000-0000-0000-000000000001', 'Config A'),
 ('dddd0015-0000-0000-0000-000000000001', 'Config B');

insert into branch (id, business_id, code, name) values
 ('cccc0015-0000-0000-0000-000000000002', 'cccc0015-0000-0000-0000-000000000001', 'CA1', 'A main'),
 ('cccc0015-0000-0000-0000-000000000003', 'cccc0015-0000-0000-0000-000000000001', 'CA2', 'A second'),
 ('dddd0015-0000-0000-0000-000000000002', 'dddd0015-0000-0000-0000-000000000001', 'CB1', 'B main');

-- WP-7: token subjects are auth identities, distinct from app_user ids.
insert into app_user (id, business_id, auth_user_id, full_name) values
 ('cccc0015-0000-0000-0000-00000000000a', 'cccc0015-0000-0000-0000-000000000001',
  md5('auth:cccc0015-0000-0000-0000-00000000000a')::uuid, 'A owner'),
 ('cccc0015-0000-0000-0000-00000000000b', 'cccc0015-0000-0000-0000-000000000001',
  md5('auth:cccc0015-0000-0000-0000-00000000000b')::uuid, 'A tailor'),
 ('dddd0015-0000-0000-0000-00000000000a', 'dddd0015-0000-0000-0000-000000000001',
  md5('auth:dddd0015-0000-0000-0000-00000000000a')::uuid, 'B owner');

insert into role (id, business_id, code, name) values
 ('cccc0015-0000-0000-0000-00000000001a', 'cccc0015-0000-0000-0000-000000000001', 'owner',  'Owner'),
 ('cccc0015-0000-0000-0000-00000000001b', 'cccc0015-0000-0000-0000-000000000001', 'tailor', 'Tailor'),
 ('dddd0015-0000-0000-0000-00000000001a', 'dddd0015-0000-0000-0000-000000000001', 'owner',  'Owner');

insert into permission (id, business_id, code, domain) values
 ('cccc0015-0000-0000-0000-00000000002a', 'cccc0015-0000-0000-0000-000000000001', 'config.manage',     'config'),
 ('cccc0015-0000-0000-0000-00000000002b', 'cccc0015-0000-0000-0000-000000000001', 'config.tax.manage', 'config'),
 ('cccc0015-0000-0000-0000-00000000002c', 'cccc0015-0000-0000-0000-000000000001', 'order.create',      'order'),
 ('dddd0015-0000-0000-0000-00000000002a', 'dddd0015-0000-0000-0000-000000000001', 'config.tax.manage', 'config');

-- The owner may change configuration. The tailor may take orders and nothing else.
insert into role_permission (business_id, role_id, permission_id) values
 ('cccc0015-0000-0000-0000-000000000001','cccc0015-0000-0000-0000-00000000001a','cccc0015-0000-0000-0000-00000000002a'),
 ('cccc0015-0000-0000-0000-000000000001','cccc0015-0000-0000-0000-00000000001a','cccc0015-0000-0000-0000-00000000002b'),
 ('cccc0015-0000-0000-0000-000000000001','cccc0015-0000-0000-0000-00000000001b','cccc0015-0000-0000-0000-00000000002c'),
 ('dddd0015-0000-0000-0000-000000000001','dddd0015-0000-0000-0000-00000000001a','dddd0015-0000-0000-0000-00000000002a');

insert into user_branch_role (business_id, user_id, branch_id, role_id) values
 ('cccc0015-0000-0000-0000-000000000001','cccc0015-0000-0000-0000-00000000000a','cccc0015-0000-0000-0000-000000000002','cccc0015-0000-0000-0000-00000000001a'),
 ('cccc0015-0000-0000-0000-000000000001','cccc0015-0000-0000-0000-00000000000b','cccc0015-0000-0000-0000-000000000002','cccc0015-0000-0000-0000-00000000001b'),
 ('dddd0015-0000-0000-0000-000000000001','dddd0015-0000-0000-0000-00000000000a','dddd0015-0000-0000-0000-000000000002','dddd0015-0000-0000-0000-00000000001a');

insert into config_setting (id, business_id, key, category, scope, value_type,
                            default_value, current_value, required_permission,
                            is_effective_dated, is_ca_validated_scope) values
 ('cccc0015-0000-0000-0000-00000000003a','cccc0015-0000-0000-0000-000000000001',
  'test.buffer_days','production','branch','integer','1','1','config.manage', true, false),
 ('cccc0015-0000-0000-0000-00000000003b','cccc0015-0000-0000-0000-000000000001',
  'test.revenue_point','finance','business','enum','"on_delivery"','"on_delivery"','config.tax.manage', true, true),
 ('cccc0015-0000-0000-0000-00000000003c','cccc0015-0000-0000-0000-000000000001',
  'test.no_current','ux','business','integer','7',null,'config.manage', false, false),
 ('dddd0015-0000-0000-0000-00000000003a','dddd0015-0000-0000-0000-000000000001',
  'test.buffer_days','production','business','integer','99','99','config.tax.manage', false, false);

insert into tax_code (id, business_id, code, kind, hsn_sac) values
 ('cccc0015-0000-0000-0000-00000000004a','cccc0015-0000-0000-0000-000000000001','STITCH','service','998821');
insert into tax_rate (id, business_id, tax_code_id, total_percent, effective_from, effective_to) values
 ('cccc0015-0000-0000-0000-00000000005a','cccc0015-0000-0000-0000-000000000001',
  'cccc0015-0000-0000-0000-00000000004a', 5.00, date '2020-01-01', date '2026-04-01'),
 ('cccc0015-0000-0000-0000-00000000005b','cccc0015-0000-0000-0000-000000000001',
  'cccc0015-0000-0000-0000-00000000004a',12.00, date '2026-04-01', null);

insert into customer (id, business_id, display_name) values
 ('cccc0015-0000-0000-0000-00000000006a','cccc0015-0000-0000-0000-000000000001','A customer');

-- ===========================================================================
-- 1 · Resolution precedence
-- ===========================================================================
-- No user context yet, so these run as the migration/console path: the tenant
-- is passed explicitly and the permission trigger stands aside.
select dhaaga_test.eq(
    app.config_int('test.no_current','cccc0015-0000-0000-0000-000000000001'),
    7, 'a setting with no current value resolves to its shipped default');

select dhaaga_test.eq(
    app.config_int('test.buffer_days','cccc0015-0000-0000-0000-000000000001'),
    1, 'a setting with a current value resolves to that, not to the default');

select dhaaga_test.eq(
    app.config_value('test.absent','cccc0015-0000-0000-0000-000000000001'),
    null::jsonb, 'an unknown key resolves to null rather than raising');

insert into config_version (id, business_id, setting_id, value, effective_from, effective_to) values
 ('cccc0015-0000-0000-0000-00000000007a','cccc0015-0000-0000-0000-000000000001',
  'cccc0015-0000-0000-0000-00000000003a','3', now() - interval '10 days', null);

select dhaaga_test.eq(
    app.config_int('test.buffer_days','cccc0015-0000-0000-0000-000000000001'),
    3, 'a business version in force outranks current_value');

insert into config_branch_override (id, business_id, branch_id, setting_id, value, effective_from) values
 ('cccc0015-0000-0000-0000-00000000008a','cccc0015-0000-0000-0000-000000000001',
  'cccc0015-0000-0000-0000-000000000003','cccc0015-0000-0000-0000-00000000003a','5', now() - interval '5 days');

select dhaaga_test.eq(
    app.config_int('test.buffer_days','cccc0015-0000-0000-0000-000000000001',
                   'cccc0015-0000-0000-0000-000000000003'),
    5, 'a branch override outranks the business version for that branch');

select dhaaga_test.eq(
    app.config_int('test.buffer_days','cccc0015-0000-0000-0000-000000000001',
                   'cccc0015-0000-0000-0000-000000000002'),
    3, 'while a branch with no override still gets the business value');

select dhaaga_test.eq(
    app.config_int('test.buffer_days','cccc0015-0000-0000-0000-000000000001',
                   'cccc0015-0000-0000-0000-000000000003', now() - interval '7 days'),
    3, 'and the same branch resolves the business value at a date before its override began');

-- Typed readers
select dhaaga_test.eq(
    app.config_text('test.revenue_point','cccc0015-0000-0000-0000-000000000001'),
    'on_delivery', 'config_text unwraps a json string rather than returning it quoted');
select dhaaga_test.eq(
    app.config_decimal('test.buffer_days','cccc0015-0000-0000-0000-000000000001'),
    3::numeric, 'config_decimal returns exact numeric');

-- ===========================================================================
-- 2 · History, and resolution at a past date (BR-15)
-- ===========================================================================
-- REGRESSION. The first draft recorded no history for a setting that had never
-- been versioned, so the first change silently rewrote the past: current_value
-- was overwritten and a past-date lookup fell through to it. Reproduced.
select dhaaga_test.eq(
    app.set_config_value('test.no_current','21'::jsonb, now(), null, null,
                         'cccc0015-0000-0000-0000-000000000001') is not null,
    true, 'a setting can be changed through set_config_value');

select dhaaga_test.eq(
    app.config_int('test.no_current','cccc0015-0000-0000-0000-000000000001'),
    21, 'the new value is in force now');

select dhaaga_test.eq(
    app.config_int('test.no_current','cccc0015-0000-0000-0000-000000000001', null, now() - interval '1 day'),
    7, 'REGRESSION: yesterday still resolves the value in force yesterday, not the new one');

select dhaaga_test.eq(
    (select count(*)::int from config_version
      where setting_id = 'cccc0015-0000-0000-0000-00000000003c'),
    2, 'and the change left two history rows: what was in force before, and what is now');

select dhaaga_test.eq(
    (select value from config_version
      where setting_id = 'cccc0015-0000-0000-0000-00000000003c' and effective_to is not null),
    '7'::jsonb, 'the closed row carries the old value');

-- The Appendix B demonstration: a future-dated change does not take effect yet.
select app.set_config_value('test.buffer_days','9'::jsonb, now() + interval '30 days', null, null,
                            'cccc0015-0000-0000-0000-000000000001');

select dhaaga_test.eq(
    app.config_int('test.buffer_days','cccc0015-0000-0000-0000-000000000001'),
    3, 'a change dated a month out does not move today''s value');

select dhaaga_test.eq(
    app.config_int('test.buffer_days','cccc0015-0000-0000-0000-000000000001', null, now() + interval '31 days'),
    9, 'but resolving a month out returns it');

select dhaaga_test.ok(
    (select current_value from config_setting where id = 'cccc0015-0000-0000-0000-00000000003a')
        is distinct from '9'::jsonb,
    'and the cached current_value was not moved forward to the future value early');

select dhaaga_test.throws(
    $$insert into config_version (business_id, setting_id, value, effective_from)
      values ('cccc0015-0000-0000-0000-000000000001','cccc0015-0000-0000-0000-00000000003a',
              '4', now() - interval '2 days')$$,
    'two values cannot apply to one setting at the same moment', '23P01');

-- Tax rates resolve the same way, which is what BR-15 rests on.
select dhaaga_test.eq(
    app.tax_rate_at('STITCH', date '2025-06-01', 'cccc0015-0000-0000-0000-000000000001'),
    5.00::numeric, 'an invoice reprinted for June 2025 resolves the rate in force then');
select dhaaga_test.eq(
    app.tax_rate_at('STITCH', date '2026-06-01', 'cccc0015-0000-0000-0000-000000000001'),
    12.00::numeric, 'while today resolves today''s rate');
select dhaaga_test.eq(
    app.tax_rate_at('STITCH', date '2019-01-01', 'cccc0015-0000-0000-0000-000000000001'),
    null::numeric, 'and a date before any rate existed resolves nothing rather than guessing');

-- ===========================================================================
-- 3 · Permission enforcement
-- ===========================================================================
select set_config('request.jwt.claims',
    json_build_object('sub',(md5('auth:cccc0015-0000-0000-0000-00000000000b')::uuid)::text,'role','authenticated')::text, true);

select dhaaga_test.eq(
    app.current_user_id(), 'cccc0015-0000-0000-0000-00000000000b'::uuid,
    'the tailor is the acting user');
select dhaaga_test.eq(
    app.has_permission('config.manage'), false, 'the tailor does not hold config.manage');
select dhaaga_test.eq(
    app.has_permission('order.create'), true, 'but does hold the permission their role grants');

select dhaaga_test.throws(
    $$select app.set_config_value('test.buffer_days','2'::jsonb)$$,
    'the tailor cannot change a setting through set_config_value', '42501');

select dhaaga_test.throws(
    $$insert into config_version (business_id, setting_id, value, effective_from)
      values ('cccc0015-0000-0000-0000-000000000001','cccc0015-0000-0000-0000-00000000003a',
              '2', now() + interval '90 days')$$,
    'nor by writing a version row directly - the check is on the table, not in the setter', '42501');

select dhaaga_test.throws(
    $$insert into config_branch_override (business_id, branch_id, setting_id, value, effective_from)
      values ('cccc0015-0000-0000-0000-000000000001','cccc0015-0000-0000-0000-000000000002',
              'cccc0015-0000-0000-0000-00000000003a','2', now() + interval '90 days')$$,
    'nor by writing a branch override', '42501');

select dhaaga_test.throws(
    $$update config_setting set current_value = '2'
       where id = 'cccc0015-0000-0000-0000-00000000003a'$$,
    'nor by updating the setting row itself', '42501');

select dhaaga_test.throws(
    $$delete from config_version where id = 'cccc0015-0000-0000-0000-00000000007a'$$,
    'nor by deleting history - DELETE is covered, not only INSERT and UPDATE', '42501');

-- REGRESSION. PostgreSQL searches the session's temporary schema first when
-- pg_temp is not named in search_path. Against the first draft, a temporary
-- table called config_setting made the required permission resolve to null and
-- the trigger waved the write through. Reproduced end to end.
create temp table config_setting (id uuid, required_permission text);

select dhaaga_test.throws(
    $$insert into config_version (business_id, setting_id, value, effective_from)
      values ('cccc0015-0000-0000-0000-000000000001','cccc0015-0000-0000-0000-00000000003a',
              '2', now() + interval '120 days')$$,
    'REGRESSION: a temporary table cannot shadow the setting the trigger reads', '42501');

drop table pg_temp.config_setting;

-- The owner, who does hold the permission, gets through.
select set_config('request.jwt.claims',
    json_build_object('sub',(md5('auth:cccc0015-0000-0000-0000-00000000000a')::uuid)::text,'role','authenticated')::text, true);

select dhaaga_test.eq(
    app.has_permission('config.manage'), true, 'the owner holds config.manage');

select dhaaga_test.lives(
    $$select app.set_config_value('test.buffer_days','4'::jsonb, now(), 'owner_decision', 'busier season')$$,
    'and can change the same setting the tailor could not');

select dhaaga_test.eq(
    app.config_int('test.buffer_days'),
    4, 'the owner''s change took effect, resolved with no business id from their own context');

select dhaaga_test.eq(
    (select changed_by from config_version
      where setting_id = 'cccc0015-0000-0000-0000-00000000003a' and value = '4'),
    'cccc0015-0000-0000-0000-00000000000a'::uuid,
    'and the history records who made it');

select dhaaga_test.eq(
    (select reason_text from config_version
      where setting_id = 'cccc0015-0000-0000-0000-00000000003a' and value = '4'),
    'busier season', 'along with why');

-- A permission of the same name in another business is not the caller's.
select dhaaga_test.throws(
    $$select app.set_config_value('test.buffer_days','1'::jsonb, now(), null, null,
                                  'dddd0015-0000-0000-0000-000000000001')$$,
    'the owner of A cannot change a setting in business B', '42501');

-- ===========================================================================
-- 4 · Tenant isolation of configuration, as authenticated
-- ===========================================================================
set local role authenticated;

select dhaaga_test.eq(
    (select count(*)::int from config_setting where business_id = 'dddd0015-0000-0000-0000-000000000001'),
    0, 'A cannot read B''s settings');
select dhaaga_test.eq(
    (select count(*)::int from config_version where business_id = 'dddd0015-0000-0000-0000-000000000001'),
    0, 'nor B''s configuration history');
select dhaaga_test.eq(
    (select count(*)::int from validation_signoff where business_id = 'dddd0015-0000-0000-0000-000000000001'),
    0, 'nor B''s sign-offs');
select dhaaga_test.eq(
    app.tax_rate_at('STITCH', current_date, 'dddd0015-0000-0000-0000-000000000001'),
    null::numeric, 'nor resolve a rate inside B by passing B''s id');
select dhaaga_test.eq(
    app.config_int('test.buffer_days','dddd0015-0000-0000-0000-000000000001'),
    null::integer, 'nor read a B setting by passing B''s id - config_value runs as the caller');

reset role;

-- ===========================================================================
-- 5 · The CA sign-off lifecycle (BR-22)
-- ===========================================================================
select dhaaga_test.eq(
    app.validation_status('tax','cccc0015-0000-0000-0000-000000000001'),
    'unvalidated', 'a business with no sign-off is unvalidated');

select set_config('request.jwt.claims',
    json_build_object('sub',(md5('auth:cccc0015-0000-0000-0000-00000000000a')::uuid)::text,'role','authenticated')::text, true);

select dhaaga_test.lives(
    $$select app.record_validation_signoff('tax','R. Sharma','Sharma & Co','SIGN/2026/01')$$,
    'the owner records a CA sign-off');

select dhaaga_test.eq(
    app.validation_status('tax'), 'validated', 'the configuration is now validated');

-- A setting outside the sign-off's scope must not disturb it.
select app.set_config_value('test.buffer_days','6'::jsonb);
select dhaaga_test.eq(
    app.validation_status('tax'), 'validated',
    'changing a setting outside the CA scope leaves the sign-off intact');

-- One inside it must.
select app.set_config_value('test.revenue_point','"on_completion"'::jsonb);
select dhaaga_test.eq(
    app.validation_status('tax'), 'stale',
    'changing a setting the sign-off covers makes it stale');

-- So must the tax table the scope includes.
select app.record_validation_signoff('tax','R. Sharma','Sharma & Co','SIGN/2026/02');
select dhaaga_test.eq(
    app.validation_status('tax'), 'validated', 'a fresh sign-off covers the new configuration');

select dhaaga_test.eq(
    (select count(*)::int from validation_signoff
      where business_id = 'cccc0015-0000-0000-0000-000000000001' and not is_current),
    1, 'and the superseded sign-off is kept, not deleted');
select dhaaga_test.eq(
    (select count(*)::int from validation_signoff
      where business_id = 'cccc0015-0000-0000-0000-000000000001' and is_current),
    1, 'with exactly one current sign-off');

update tax_rate set total_percent = 18.00 where id = 'cccc0015-0000-0000-0000-00000000005b';
select dhaaga_test.eq(
    app.validation_status('tax'), 'stale',
    'moving a tax rate also invalidates the sign-off - the scope is not settings alone');

-- ===========================================================================
-- 6 · The watermark BR-22 is visible through
-- ===========================================================================
insert into invoice (id, business_id, branch_id, invoice_no, doc_type, customer_id, invoice_date)
values ('cccc0015-0000-0000-0000-00000000009a','cccc0015-0000-0000-0000-000000000001',
        'cccc0015-0000-0000-0000-000000000002','INV-STALE','tax_invoice',
        'cccc0015-0000-0000-0000-00000000006a', current_date);

select dhaaga_test.eq(
    (select is_draft_watermarked from invoice where id = 'cccc0015-0000-0000-0000-00000000009a'),
    true, 'a tax invoice issued while the sign-off is stale prints as a draft');

insert into invoice (id, business_id, branch_id, invoice_no, doc_type, customer_id, invoice_date)
values ('cccc0015-0000-0000-0000-00000000009b','cccc0015-0000-0000-0000-000000000001',
        'cccc0015-0000-0000-0000-000000000002','EST-1','estimate',
        'cccc0015-0000-0000-0000-00000000006a', current_date);

select dhaaga_test.eq(
    (select is_draft_watermarked from invoice where id = 'cccc0015-0000-0000-0000-00000000009b'),
    false, 'an estimate carries no watermark: it makes no tax claim needing validation');

select app.record_validation_signoff('tax','R. Sharma','Sharma & Co','SIGN/2026/03');

insert into invoice (id, business_id, branch_id, invoice_no, doc_type, customer_id, invoice_date)
values ('cccc0015-0000-0000-0000-00000000009c','cccc0015-0000-0000-0000-000000000001',
        'cccc0015-0000-0000-0000-000000000002','INV-OK','tax_invoice',
        'cccc0015-0000-0000-0000-00000000006a', current_date);

select dhaaga_test.eq(
    (select is_draft_watermarked from invoice where id = 'cccc0015-0000-0000-0000-00000000009c'),
    false, 'once the configuration is signed off, a tax invoice prints clean');

-- A document already issued does not change its mind later.
select app.set_config_value('test.revenue_point','"on_invoice"'::jsonb);
select dhaaga_test.eq(
    (select is_draft_watermarked from invoice where id = 'cccc0015-0000-0000-0000-00000000009c'),
    false, 'and a later configuration change does not retroactively watermark it');

-- REGRESSION. The first draft fired on INSERT only, so relabelling an estimate
-- as a tax invoice produced an unwatermarked tax invoice under a stale sign-off.
select dhaaga_test.eq(
    app.validation_status('tax'), 'stale', 'the sign-off is stale again after that change');
update invoice set doc_type = 'tax_invoice' where id = 'cccc0015-0000-0000-0000-00000000009b';
select dhaaga_test.eq(
    (select is_draft_watermarked from invoice where id = 'cccc0015-0000-0000-0000-00000000009b'),
    true, 'REGRESSION: relabelling an estimate as a tax invoice re-evaluates the watermark');

-- ===========================================================================
-- 7 · Boundaries around the SECURITY DEFINER surface (ADR-0010, ADR-0011)
-- ===========================================================================
-- REGRESSION. validation_status reads validation_signoff past row-level
-- security. In the first draft it accepted any business id and answered,
-- so any authenticated caller could ask whether a competitor's books were
-- signed off. Reproduced.
select dhaaga_test.throws(
    $$select app.validation_status('tax','dddd0015-0000-0000-0000-000000000001')$$,
    'REGRESSION: a caller cannot ask for another business''s validation status', '42501');

select dhaaga_test.throws(
    $$select app.config_hash('tax','dddd0015-0000-0000-0000-000000000001')$$,
    'nor fingerprint another business''s configuration', '42501');

-- A domain with no defined scope is refused rather than fingerprinted with the
-- wrong one, which would record a sign-off that covers something else.
select dhaaga_test.throws(
    $$select app.config_hash('payroll')$$,
    'a validation domain with no defined scope is refused, not approximated', '0A000');
select dhaaga_test.throws(
    $$select app.record_validation_signoff('payroll','R. Sharma')$$,
    'so a sign-off cannot be recorded for it either', '0A000');

-- Function privileges: the control established by ADR-0010.
select dhaaga_test.eq(
    coalesce((select string_agg(p.proname, ', ' order by p.proname)
              from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'app' and p.prosecdef
                and (p.proconfig is null
                     or not exists (select 1 from unnest(p.proconfig) c where c like 'search_path=%'))), ''),
    '', 'every SECURITY DEFINER function still pins its search_path');

-- WP-6 extends the rule: an INVOKER function that names a relation without a
-- schema is shadowable through pg_temp too, so the configuration surface pins
-- its search_path whether it is DEFINER or not.
select dhaaga_test.eq(
    coalesce((select string_agg(p.proname, ', ' order by p.proname)
              from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'app'
                and p.proname in ('config_value','config_text','config_int','config_decimal',
                                  'config_bool','tax_rate_at','enforce_config_permission',
                                  'set_invoice_watermark','assert_tenant_read')
                and (p.proconfig is null
                     or not exists (select 1 from unnest(p.proconfig) c where c like 'search_path=%'))), ''),
    '', 'and so does every WP-6 function that names a relation');

select dhaaga_test.eq(
    coalesce((select string_agg(p.proname, ', ' order by p.proname)
              from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'app'
                and p.proname in ('has_permission','config_value','config_text','config_int',
                                  'config_decimal','config_bool','set_config_value','tax_rate_at',
                                  'config_hash','validation_status','record_validation_signoff',
                                  'enforce_config_permission','set_invoice_watermark','assert_tenant_read')
                and (has_function_privilege('public', p.oid, 'EXECUTE')
                     or has_function_privilege('anon', p.oid, 'EXECUTE'))), ''),
    '', 'no WP-6 function is executable by PUBLIC or by the anonymous role');

select dhaaga_test.eq(
    has_function_privilege('authenticated', 'app.config_hash(text,uuid)', 'EXECUTE'),
    false, 'the fingerprint is machinery: application users cannot call it');
select dhaaga_test.eq(
    has_function_privilege('authenticated', 'app.assert_tenant_read(uuid)', 'EXECUTE'),
    false, 'nor the boundary check itself');
select dhaaga_test.eq(
    has_function_privilege('authenticated', 'app.validation_status(text,uuid)', 'EXECUTE'),
    true, 'but they can ask whether their own configuration is validated');
select dhaaga_test.eq(
    has_function_privilege('authenticated', 'app.config_value(text,uuid,uuid,timestamptz)', 'EXECUTE'),
    true, 'and read configuration, which the app does constantly');

-- ===========================================================================
-- 8 · The audit trail sees configuration changes (BR-13)
-- ===========================================================================
select dhaaga_test.ok(
    (select count(*) > 0 from audit_event
      where entity_type = 'config_version'
        and business_id = 'cccc0015-0000-0000-0000-000000000001'),
    'every configuration change is in the audit trail');

select dhaaga_test.ok(
    (select count(*) > 0 from audit_event
      where entity_type = 'validation_signoff'
        and business_id = 'cccc0015-0000-0000-0000-000000000001'),
    'and so is every sign-off');
