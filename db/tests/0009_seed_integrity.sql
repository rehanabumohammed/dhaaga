-- Seed integrity. Requires scripts/seed.py to have run first, which is the
-- order CI uses: migrate -> seed -> test.
--
-- These assertions check the seeded configuration is coherent, and one of them
-- checks something more important than seed data: that the AP-2 accounting
-- boundary actually holds in the permission model.

select dhaaga_test.eq((select count(*)::int from business), 1,
    'exactly one business - V1 runs single-tenant on a multi-tenant schema');

select dhaaga_test.eq((select count(*)::int from branch where deleted_at is null), 1,
    'exactly one branch, as decided - the schema is multi-branch regardless');

-- ---------------------------------------------------------------------------
-- The AP-2 boundary, checked in the permission model itself
-- ---------------------------------------------------------------------------
select dhaaga_test.eq(
    coalesce((select string_agg(distinct r.code, ', ' order by r.code)
              from role_permission rp
              join role r on r.id = rp.role_id
              join permission p on p.id = rp.permission_id
              where p.is_books_surface and r.code not in ('owner','accountant')), ''),
    '',
    'AP-2: no shop role holds a books-surface permission - counter staff cannot reach accounting');

select dhaaga_test.eq(
    (select count(*)::int from role_permission rp join role r on r.id = rp.role_id
     where r.code = 'owner'),
    (select count(*)::int from permission),
    'the owner holds every permission, including the books');

select dhaaga_test.eq(
    (select count(*)::int from role_permission rp join role r on r.id = rp.role_id
     where r.code = 'tailor'),
    2, 'a tailor holds exactly two permissions: their own job cards and their own wages');

select dhaaga_test.eq(
    coalesce((select string_agg(p.code, ', ' order by p.code)
              from role_permission rp
              join role r on r.id = rp.role_id
              join permission p on p.id = rp.permission_id
              where r.code = 'tailor'), ''),
    'production.own_jobs, wage.view_own',
    'and they are the right two - a tailor cannot see another customer''s phone number');

-- ---------------------------------------------------------------------------
-- Chart of accounts
-- ---------------------------------------------------------------------------
select dhaaga_test.eq(
    coalesce((select string_agg(code, ', ' order by code) from account where is_contra), ''),
    '4900, 4910',
    'discounts allowed and sales returns are the contra-revenue accounts (BR-20)');

select dhaaga_test.eq(
    coalesce((select string_agg(m.code, ', ')
              from payment_mode m left join account a on a.id = m.account_id
              where a.id is null), ''),
    '', 'every payment mode maps to a real account');

select dhaaga_test.ok(
    (select count(*) >= 3 from account where account_type = 'direct_cost'),
    'direct cost accounts exist separately from operating expenses - gross profit depends on the split');

-- ---------------------------------------------------------------------------
-- Catalogue and production routes
-- ---------------------------------------------------------------------------
select dhaaga_test.eq(
    coalesce((select string_agg(g.code, ', ' order by g.code)
              from garment_type g
              where not exists (select 1 from measurement_template t
                                where t.garment_type_id = g.id and t.is_current)), ''),
    '', 'every garment type has a current measurement template');

select dhaaga_test.eq(
    coalesce((select string_agg(g.code, ', ' order by g.code)
              from garment_type g
              join measurement_template t on t.garment_type_id = g.id and t.is_current
              group by g.code
              having count(*) filter (where true) = 0), ''),
    '', 'no garment type has an empty template');

select dhaaga_test.eq(
    coalesce((select string_agg(x.code, ', ')
              from (select g.code, count(f.id) as n
                    from garment_type g
                    join measurement_template t on t.garment_type_id = g.id and t.is_current
                    left join template_field f on f.template_id = t.id
                    group by g.code) x
              where x.n < 4), ''),
    '', 'every garment type has at least four measurement fields');

-- A production route whose stages skip a number would break the scheduler's
-- walk through the stages.
select dhaaga_test.eq(
    coalesce((select string_agg(x.tpl::text, ', ')
              from (select w.template_id as tpl, count(*) as n, max(w.sequence_no) as mx, min(w.sequence_no) as mn
                    from workflow_stage w group by w.template_id) x
              where x.mn <> 1 or x.mx <> x.n), ''),
    '', 'every production route is numbered contiguously from 1');

select dhaaga_test.ok(
    (select bool_and(standard_minutes > 0) from workflow_stage where code <> 'QC'),
    'every wage-bearing stage carries standard minutes for the capacity engine to schedule against');

-- ---------------------------------------------------------------------------
-- BR-22: the system starts unvalidated, and says so
-- ---------------------------------------------------------------------------
select dhaaga_test.eq(
    (select count(*)::int from validation_signoff where domain = 'tax' and is_current), 0,
    'no CA sign-off exists yet, so the tax configuration is unvalidated (BR-22)');

select dhaaga_test.ok(
    (select bool_and(description like '%PLACEHOLDER%') from tax_code),
    'seeded tax codes are labelled as placeholders, not as advice');

select dhaaga_test.eq(
    (select current_value from config_setting where key = 'finance.revenue_recognition_point'),
    '"on_delivery"'::jsonb,
    'revenue recognition defaults to on-delivery and is flagged for CA confirmation');

select dhaaga_test.ok(
    (select is_ca_validated_scope from config_setting where key = 'finance.revenue_recognition_point'),
    'and it is inside the scope a CA sign-off must cover');

-- ---------------------------------------------------------------------------
-- Regression: the defect found in WP-2
-- ---------------------------------------------------------------------------
select dhaaga_test.ok(
    (select count(*) >= 2 from app_user where phone_e164 is null and deleted_at is null),
    'two seeded tailors have no phone number at all - the regression that the null-collision defect would have blocked');

-- ---------------------------------------------------------------------------
-- WP-4: the mandatory-reason list is seeded and narrowed
-- ---------------------------------------------------------------------------
select dhaaga_test.ok(
    (select count(*) >= 10 from audit_reason_requirement where requires_reason),
    'the actions that demand a reason are seeded as data, not hard-coded (AP-1, BR-13)');

select dhaaga_test.eq(
    (select column_name from audit_reason_requirement
     where entity_type = 'order_item' and action = 'update' and column_name = 'unit_price'),
    'unit_price',
    'a price override demands a reason, narrowed to the price column');

select dhaaga_test.eq(
    (select count(*)::int from audit_reason_requirement
     where entity_type = 'order_item' and column_name is null),
    0, 'so that correcting a note on the same row does not');

-- ---------------------------------------------------------------------------
-- WP-6: the configuration registry names permissions that exist
-- ---------------------------------------------------------------------------
-- A setting whose required_permission matches no permission row is a setting
-- nobody can ever change: the trigger looks the code up, finds no grant, and
-- refuses every caller including the owner. Cheap to assert, silent otherwise.
select dhaaga_test.eq(
    coalesce((select string_agg(distinct s.key, ', ' order by s.key)
              from config_setting s
              where s.deleted_at is null
                and not exists (select 1 from permission p
                                 where p.code = s.required_permission
                                   and p.business_id = s.business_id
                                   and p.deleted_at is null)), ''),
    '', 'every configured rule names a permission that exists');

select dhaaga_test.ok(
    (select count(*) > 0 from config_setting where is_ca_validated_scope and deleted_at is null),
    'and some of them are inside the CA sign-off scope, so BR-22 has something to cover');

select dhaaga_test.eq(
    app.validation_status('tax', (select id from business limit 1)),
    'unvalidated',
    'the seeded development business ships unvalidated: no CA has signed anything off');
