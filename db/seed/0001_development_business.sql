-- Development seed: one business, one branch, staff, catalogue, chart of
-- accounts and the configuration registry.
--
-- Idempotent by construction: every row has a deterministic id derived from a
-- stable key, and every insert carries `on conflict (id) do nothing`. Running
-- the seed twice is a no-op, which is what makes it safe in CI and safe to
-- re-run after a partial failure.
--
-- Reflects the recorded decisions: Supabase Cloud in an Indian region, ONE
-- branch in V1 with the schema fully multi-branch, per-branch GSTIN capability,
-- English active with Hindi present from P0.

-- ===========================================================================
-- Business and branch
-- ===========================================================================
insert into business (id, legal_name, trade_name, default_locale, currency_code, financial_year_start_month)
values (md5('business:dhaaga-dev')::uuid, 'Dhaaga Tailors (Development)', 'Dhaaga', 'en-IN', 'INR', 4)
on conflict (id) do nothing;

insert into branch (id, business_id, code, name, timezone, state_code)
values (md5('branch:main')::uuid, md5('business:dhaaga-dev')::uuid, 'BR1', 'Main Branch', 'Asia/Kolkata', '06')
on conflict (id) do nothing;

-- ===========================================================================
-- Locales — English active, Hindi present from P0 (decision 3)
-- ===========================================================================
insert into locale (id, business_id, code, name, native_name, direction, is_default, is_active, sort_order) values
 (md5('locale:en-IN')::uuid, md5('business:dhaaga-dev')::uuid, 'en-IN', 'English', 'English', 'ltr', true,  true,  10),
 (md5('locale:hi-IN')::uuid, md5('business:dhaaga-dev')::uuid, 'hi-IN', 'Hindi',   'हिन्दी',  'ltr', false, false, 20)
on conflict (id) do nothing;

-- ===========================================================================
-- Permissions
-- ===========================================================================
-- is_books_surface marks the accounting boundary of AP-2: no role that lacks
-- these may reach a screen containing accounting vocabulary (BR-23).
insert into permission (id, business_id, code, domain, description, is_books_surface)
select md5('perm:' || p.code)::uuid, md5('business:dhaaga-dev')::uuid, p.code, p.domain, p.description, p.books
from (values
 ('customer.view',        'customer',   'See customers and their history',            false),
 ('customer.manage',      'customer',   'Create and edit customers and contacts',     false),
 ('customer.merge',       'customer',   'Merge and unmerge customer records',         false),
 ('measurement.view',     'customer',   'See measurements',                           false),
 ('measurement.manage',   'customer',   'Record and revise measurements',             false),
 ('order.view',           'order',      'See orders',                                 false),
 ('order.create',         'order',      'Take an order',                              false),
 ('order.cancel',         'order',      'Cancel an order',                            false),
 ('order.discount',       'order',      'Apply a discount within the role limit',     false),
 ('order.price_override', 'order',      'Override a price',                           false),
 ('order.date_override',  'order',      'Override a calculated promise date',         false),
 ('production.view',      'production', 'See the production board',                   false),
 ('production.assign',    'production', 'Assign work to a tailor',                    false),
 ('production.advance',   'production', 'Move a garment to the next stage',           false),
 ('production.own_jobs',  'production', 'See and update only your own job cards',     false),
 ('delivery.handover',    'delivery',   'Hand garments over to a customer',           false),
 ('payment.take',         'money',      'Take a payment',                             false),
 ('payment.reverse',      'money',      'Reverse a payment',                          false),
 ('payment.refund',       'money',      'Refund a customer',                          false),
 ('cash.close',           'money',      'Close the drawer',                           false),
 ('stock.view',           'stock',      'See stock',                                  false),
 ('stock.manage',         'stock',      'Receive, issue and transfer stock',          false),
 ('stock.adjust',         'stock',      'Adjust stock with a reason',                 false),
 ('wage.view_own',        'wage',       'See your own wage ledger',                   false),
 ('wage.manage',          'wage',       'Set rates and run payouts',                  true),
 ('config.view',          'config',     'See configuration',                          false),
 ('config.manage',        'config',     'Change configuration',                       false),
 ('config.tax.manage',    'config',     'Change tax configuration',                   true),
 ('config.production.manage','config',  'Change capacity, calendars and workflows',   false),
 ('user.manage',          'admin',      'Create people, and grant or revoke their branch access', false),
 ('role.manage',          'admin',      'Define roles and what each one may do',      false),
 ('business.manage',      'admin',      'Edit the business record, GSTIN and address', false),
 ('branch.manage',        'admin',      'Open and edit branches',                     false),
 ('report.operations',    'report',     'See operational reports',                    false),
 ('books.view',           'books',      'See the ledger, profit and loss and cash flow', true),
 ('books.export',         'books',      'Export accounting data',                     true),
 ('audit.view',           'admin',      'Read the audit trail',                       false)
) as p(code, domain, description, books)
on conflict (id) do nothing;

-- ===========================================================================
-- Roles
-- ===========================================================================
insert into role (id, business_id, code, name, description, is_system, sort_order)
select md5('role:' || r.code)::uuid, md5('business:dhaaga-dev')::uuid, r.code, r.name, r.description, true, r.sort
from (values
 ('owner',          'Owner',          'Everything, all branches, including the books',            10),
 ('accountant',     'Accountant',     'The books only: ledger, reports, exports, tax settings',   20),
 ('branch_manager', 'Branch Manager', 'One branch: orders, assignment, stock, day close',         30),
 ('counter_staff',  'Counter Staff',  'Customers, measurements, orders, payments, deliveries',    40),
 ('master_cutter',  'Master Cutter',  'Cutting queue, fabric issue, job cards',                   50),
 ('tailor',         'Tailor',         'Own job cards and own wage ledger only',                   60),
 ('delivery_qc',    'Delivery / QC',  'Trials, alteration intake, handover, collection',          70)
) as r(code, name, description, sort)
on conflict (id) do nothing;

-- Role to permission mapping. The tailor deliberately sees almost nothing: only
-- their own job cards and their own wages.
insert into role_permission (id, business_id, role_id, permission_id)
select md5('rp:' || rp.role_code || ':' || rp.perm_code)::uuid,
       md5('business:dhaaga-dev')::uuid,
       md5('role:' || rp.role_code)::uuid,
       md5('perm:' || rp.perm_code)::uuid
from (values
 ('accountant','books.view'), ('accountant','books.export'), ('accountant','config.tax.manage'),
 ('accountant','report.operations'), ('accountant','audit.view'), ('accountant','wage.manage'),

 ('branch_manager','customer.view'), ('branch_manager','customer.manage'), ('branch_manager','customer.merge'),
 ('branch_manager','measurement.view'), ('branch_manager','measurement.manage'),
 ('branch_manager','order.view'), ('branch_manager','order.create'), ('branch_manager','order.cancel'),
 ('branch_manager','order.discount'), ('branch_manager','order.date_override'),
 ('branch_manager','production.view'), ('branch_manager','production.assign'), ('branch_manager','production.advance'),
 ('branch_manager','delivery.handover'), ('branch_manager','payment.take'), ('branch_manager','payment.reverse'),
 ('branch_manager','cash.close'), ('branch_manager','stock.view'), ('branch_manager','stock.manage'),
 ('branch_manager','stock.adjust'), ('branch_manager','report.operations'), ('branch_manager','audit.view'),

 ('counter_staff','customer.view'), ('counter_staff','customer.manage'),
 ('counter_staff','measurement.view'), ('counter_staff','measurement.manage'),
 ('counter_staff','order.view'), ('counter_staff','order.create'), ('counter_staff','order.discount'),
 ('counter_staff','delivery.handover'), ('counter_staff','payment.take'), ('counter_staff','production.view'),

 ('master_cutter','production.view'), ('master_cutter','production.advance'),
 ('master_cutter','stock.view'), ('master_cutter','stock.manage'), ('master_cutter','measurement.view'),

 ('tailor','production.own_jobs'), ('tailor','wage.view_own'),

 ('delivery_qc','customer.view'), ('delivery_qc','order.view'), ('delivery_qc','production.view'),
 ('delivery_qc','production.advance'), ('delivery_qc','delivery.handover'), ('delivery_qc','payment.take')
) as rp(role_code, perm_code)
on conflict (id) do nothing;

-- The owner holds every permission, including the books surface.
insert into role_permission (id, business_id, role_id, permission_id)
select md5('rp:owner:' || p.code)::uuid, md5('business:dhaaga-dev')::uuid,
       md5('role:owner')::uuid, p.id
from permission p where p.business_id = md5('business:dhaaga-dev')::uuid
on conflict (id) do nothing;

-- ===========================================================================
-- Staff
-- ===========================================================================
-- auth_user_id is the Supabase Auth subject this person signs in as, and is
-- deliberately NOT the same value as id (WP-7): the two are different facts and
-- a seed that made them equal would hide any code that confuses them.
--
-- The two tailors have no auth identity at all. That is the point of the column
-- being nullable: they have no phone, so they cannot receive an OTP, and they
-- are still people the shop pays and assigns work to.
insert into app_user (id, business_id, auth_user_id, full_name, display_name, phone_e164, employee_code, locale, status) values
 (md5('user:owner')::uuid,   md5('business:dhaaga-dev')::uuid, md5('auth:owner')::uuid,   'Shop Owner',    'Owner',   '+919000000001', 'EMP-001', 'en-IN', 'active'),
 (md5('user:counter')::uuid, md5('business:dhaaga-dev')::uuid, md5('auth:counter')::uuid, 'Counter Staff', 'Counter', '+919000000002', 'EMP-002', 'en-IN', 'active'),
 (md5('user:cutter')::uuid,  md5('business:dhaaga-dev')::uuid, md5('auth:cutter')::uuid,  'Master Cutter', 'Cutter',  '+919000000003', 'EMP-003', 'en-IN', 'active'),
 -- Deliberately no phone number and no employee code: tailors often have
 -- neither, and the schema must not require them (defect found in WP-2).
 (md5('user:tailor1')::uuid, md5('business:dhaaga-dev')::uuid, null, 'Imran (tailor)', 'Imran',  null, null, 'hi-IN', 'active'),
 (md5('user:tailor2')::uuid, md5('business:dhaaga-dev')::uuid, null, 'Sana (tailor)',  'Sana',   null, null, 'hi-IN', 'active')
on conflict (id) do nothing;

insert into user_branch_role (id, business_id, user_id, branch_id, role_id)
select md5('ubr:' || u.key || ':' || u.role_code)::uuid, md5('business:dhaaga-dev')::uuid,
       md5('user:' || u.key)::uuid, md5('branch:main')::uuid, md5('role:' || u.role_code)::uuid
from (values
 ('owner','owner'), ('counter','counter_staff'), ('cutter','master_cutter'),
 ('tailor1','tailor'), ('tailor2','tailor')
) as u(key, role_code)
on conflict (id) do nothing;

-- ===========================================================================
-- Chart of accounts (§4)
-- ===========================================================================
insert into account (id, business_id, code, name, account_type, normal_balance, is_contra, is_system)
select md5('account:' || a.code)::uuid, md5('business:dhaaga-dev')::uuid, a.code, a.name, a.atype, a.nbal, a.contra, true
from (values
 ('1100','Cash in hand',            'asset',       'debit',  false),
 ('1110','Bank',                    'asset',       'debit',  false),
 ('1120','UPI clearing',            'asset',       'debit',  false),
 ('1200','Accounts receivable',     'asset',       'debit',  false),
 ('1300','Inventory - fabric',      'asset',       'debit',  false),
 ('1310','Inventory - trims',       'asset',       'debit',  false),
 ('1400','Advances to staff',       'asset',       'debit',  false),
 ('1410','Advances to suppliers',   'asset',       'debit',  false),
 ('2100','Customer advances',       'liability',   'credit', false),
 ('2110','Customer credit balances','liability',   'credit', false),
 ('2200','Wages payable',           'liability',   'credit', false),
 ('2300','Supplier payable',        'liability',   'credit', false),
 ('2400','Tax payable - CGST',      'liability',   'credit', false),
 ('2410','Tax payable - SGST',      'liability',   'credit', false),
 ('2420','Tax payable - IGST',      'liability',   'credit', false),
 ('3000','Opening balance equity',  'equity',      'credit', false),
 ('4100','Sales - stitching',       'revenue',     'credit', false),
 ('4110','Sales - fabric',          'revenue',     'credit', false),
 ('4120','Sales - alteration',      'revenue',     'credit', false),
 ('4200','Other income',            'revenue',     'credit', false),
 ('4900','Discounts allowed',       'revenue',     'debit',  true),
 ('4910','Sales returns',           'revenue',     'debit',  true),
 ('5100','Material cost - fabric',  'direct_cost', 'debit',  false),
 ('5110','Material cost - trims',   'direct_cost', 'debit',  false),
 ('5200','Direct labour - piece rate','direct_cost','debit', false),
 ('5210','Direct labour - salaried', 'direct_cost','debit',  false),
 ('5300','Outsourced work',         'direct_cost', 'debit',  false),
 ('6100','Rent',                    'expense',     'debit',  false),
 ('6110','Electricity',             'expense',     'debit',  false),
 ('6120','Salaries - non-production','expense',    'debit',  false),
 ('6130','Transport',               'expense',     'debit',  false),
 ('6140','Marketing',               'expense',     'debit',  false),
 ('6150','Repairs and maintenance', 'expense',     'debit',  false),
 ('6160','Payment charges',         'expense',     'debit',  false),
 ('6900','Miscellaneous',           'expense',     'debit',  false),
 ('9100','Cash over / short',       'control',     'debit',  false),
 ('9110','Rounding',                'control',     'debit',  false),
 ('9120','Suspense',                'control',     'debit',  false)
) as a(code, name, atype, nbal, contra)
on conflict (id) do nothing;

-- ===========================================================================
-- Payment modes
-- ===========================================================================
insert into payment_mode (id, business_id, code, label, account_id, requires_reference, is_cash, sort_order)
select md5('paymode:' || m.code)::uuid, md5('business:dhaaga-dev')::uuid, m.code, m.label,
       md5('account:' || m.account_code)::uuid, m.needs_ref, m.is_cash, m.sort
from (values
 ('CASH','Cash',          '1100', false, true,  10),
 ('UPI','UPI',            '1120', true,  false, 20),
 ('CARD','Card',          '1110', true,  false, 30),
 ('BANK','Bank transfer', '1110', true,  false, 40)
) as m(code, label, account_code, needs_ref, is_cash, sort)
on conflict (id) do nothing;

-- ===========================================================================
-- Reason codes (AP-1: controlled lists are data)
-- ===========================================================================
insert into reason_code (id, business_id, domain, code, label, requires_text, sort_order)
select md5('reason:' || r.domain || ':' || r.code)::uuid, md5('business:dhaaga-dev')::uuid,
       r.domain, r.code, r.label, r.needs_text, r.sort
from (values
 ('date_override','customer_insisted','Customer insisted',        false, 10),
 ('date_override','wedding_date',     'Wedding or event date',    false, 20),
 ('date_override','management',       'Management decision',      false, 30),
 ('date_override','error_correction', 'Correcting an error',      false, 40),
 ('date_override','other',            'Other',                    true,  99),
 ('discount','regular_customer',      'Regular customer',         false, 10),
 ('discount','bulk_order',            'Bulk order',               false, 20),
 ('discount','goodwill',              'Goodwill',                 false, 30),
 ('discount','other',                 'Other',                    true,  99),
 ('order_cancellation','customer_changed_mind','Customer changed their mind', false, 10),
 ('order_cancellation','cannot_deliver','Cannot deliver in time',  false, 20),
 ('order_cancellation','other',       'Other',                    true,  99),
 ('stock_wastage','cutting_loss',     'Cutting loss',             false, 10),
 ('stock_wastage','damaged',          'Damaged',                  false, 20),
 ('stock_wastage','other',            'Other',                    true,  99),
 ('stock_adjustment','count_variance','Physical count variance',  true,  10),
 ('stock_adjustment','other',         'Other',                    true,  99),
 ('payment_reversal','entered_twice', 'Entered twice',            false, 10),
 ('payment_reversal','wrong_amount',  'Wrong amount',             false, 20),
 ('payment_reversal','wrong_customer','Wrong customer',           false, 30),
 ('payment_reversal','other',         'Other',                    true,  99),
 ('alteration','fit_issue',           'Fit issue',                false, 10),
 ('alteration','customer_preference', 'Customer preference change',false, 20),
 ('alteration','workmanship',         'Workmanship',              false, 30),
 ('alteration','other',               'Other',                    true,  99),
 ('number_void','lease_expired',      'Offline lease expired unused', false, 10),
 ('material_writeoff','lost',         'Lost',                     true,  10),
 ('material_writeoff','damaged',      'Damaged in production',    true,  20)
) as r(domain, code, label, needs_text, sort)
on conflict (id) do nothing;

-- ===========================================================================
-- Priority classes
-- ===========================================================================
insert into priority_class (id, business_id, code, label, queue_weight, is_default, sort_order) values
 (md5('priority:normal')::uuid, md5('business:dhaaga-dev')::uuid, 'normal', 'Normal', 100, true,  10),
 (md5('priority:urgent')::uuid, md5('business:dhaaga-dev')::uuid, 'urgent', 'Urgent', 300, false, 20),
 (md5('priority:vip')::uuid,    md5('business:dhaaga-dev')::uuid, 'vip',    'VIP',    500, false, 30)
on conflict (id) do nothing;

-- ===========================================================================
-- Catalogue: garment types, measurement templates, workflow routes
-- ===========================================================================
insert into garment_type (id, business_id, code, name, gender_applicability, default_turnaround_days, requires_trial, sort_order)
select md5('gtype:' || g.code)::uuid, md5('business:dhaaga-dev')::uuid, g.code, g.name, g.gender, g.days, g.trial, g.sort
from (values
 ('SHIRT',   'Shirt',   'any',    7,  false, 10),
 ('TROUSER', 'Trouser', 'any',    7,  false, 20),
 ('KURTA',   'Kurta',   'any',    10, false, 30),
 ('BLOUSE',  'Blouse',  'female', 10, true,  40),
 ('BLAZER',  'Blazer',  'any',    21, true,  50)
) as g(code, name, gender, days, trial, sort)
on conflict (id) do nothing;

insert into measurement_template (id, business_id, garment_type_id, version, is_current)
select md5('mtpl:' || g.code)::uuid, md5('business:dhaaga-dev')::uuid, md5('gtype:' || g.code)::uuid, 1, true
from (values ('SHIRT'),('TROUSER'),('KURTA'),('BLOUSE'),('BLAZER')) as g(code)
on conflict (id) do nothing;

insert into template_field (id, business_id, template_id, code, label, unit, input_type, min_value, max_value, is_required, group_name, display_order)
select md5('tfield:' || f.gtype || ':' || f.code)::uuid, md5('business:dhaaga-dev')::uuid,
       md5('mtpl:' || f.gtype)::uuid, f.code, f.label, 'inch', 'decimal', f.minv, f.maxv, f.req, f.grp, f.ord
from (values
 ('SHIRT','length','Length',      20, 45, true,  'body',   10),
 ('SHIRT','chest','Chest',        24, 70, true,  'body',   20),
 ('SHIRT','waist','Waist',        20, 70, false, 'body',   30),
 ('SHIRT','shoulder','Shoulder',  12, 26, true,  'body',   40),
 ('SHIRT','sleeve','Sleeve',      15, 30, true,  'arm',    50),
 ('SHIRT','collar','Collar',      12, 22, true,  'neck',   60),
 ('SHIRT','cuff','Cuff',           6, 14, false, 'arm',    70),
 ('TROUSER','length','Length',    30, 50, true,  'body',   10),
 ('TROUSER','waist','Waist',      22, 60, true,  'body',   20),
 ('TROUSER','hip','Hip',          28, 70, true,  'body',   30),
 ('TROUSER','thigh','Thigh',      16, 40, true,  'leg',    40),
 ('TROUSER','knee','Knee',        12, 30, false, 'leg',    50),
 ('TROUSER','bottom','Bottom',     8, 24, true,  'leg',    60),
 ('KURTA','length','Length',      30, 55, true,  'body',   10),
 ('KURTA','chest','Chest',        24, 70, true,  'body',   20),
 ('KURTA','shoulder','Shoulder',  12, 26, true,  'body',   30),
 ('KURTA','sleeve','Sleeve',      15, 30, true,  'arm',    40),
 ('KURTA','neck','Neck',           4, 16, false, 'neck',   50),
 ('BLOUSE','length','Length',     10, 26, true,  'body',   10),
 ('BLOUSE','bust','Bust',         24, 60, true,  'body',   20),
 ('BLOUSE','waist','Waist',       20, 55, true,  'body',   30),
 ('BLOUSE','shoulder','Shoulder', 10, 22, true,  'body',   40),
 ('BLOUSE','sleeve','Sleeve',      2, 26, true,  'arm',    50),
 ('BLAZER','length','Length',     24, 40, true,  'body',   10),
 ('BLAZER','chest','Chest',       28, 70, true,  'body',   20),
 ('BLAZER','waist','Waist',       24, 65, true,  'body',   30),
 ('BLAZER','shoulder','Shoulder', 14, 26, true,  'body',   40),
 ('BLAZER','sleeve','Sleeve',     18, 30, true,  'arm',    50)
) as f(gtype, code, label, minv, maxv, req, grp, ord)
on conflict (id) do nothing;

-- Style options, shirt only for now. extra_minutes feeds the capacity engine.
insert into style_option_group (id, business_id, garment_type_id, code, label, selection_type, is_required, sort_order) values
 (md5('sgrp:SHIRT:collar')::uuid, md5('business:dhaaga-dev')::uuid, md5('gtype:SHIRT')::uuid, 'collar', 'Collar', 'single', true, 10),
 (md5('sgrp:SHIRT:cuff')::uuid,   md5('business:dhaaga-dev')::uuid, md5('gtype:SHIRT')::uuid, 'cuff',   'Cuff',   'single', true, 20),
 (md5('sgrp:SHIRT:pocket')::uuid, md5('business:dhaaga-dev')::uuid, md5('gtype:SHIRT')::uuid, 'pocket', 'Pocket', 'single', false, 30)
on conflict (id) do nothing;

insert into style_option (id, business_id, group_id, code, label, price_delta, extra_minutes, sort_order)
select md5('sopt:' || s.grp || ':' || s.code)::uuid, md5('business:dhaaga-dev')::uuid,
       md5('sgrp:SHIRT:' || s.grp)::uuid, s.code, s.label, s.delta, s.mins, s.sort
from (values
 ('collar','regular','Regular',      0,  0, 10),
 ('collar','mandarin','Mandarin',    0, 10, 20),
 ('collar','button_down','Button down', 50, 15, 30),
 ('cuff','single','Single',          0,  0, 10),
 ('cuff','double','Double (French)',80, 20, 20),
 ('pocket','none','None',            0,  0, 10),
 ('pocket','one','One',              0,  8, 20),
 ('pocket','two','Two',             30, 16, 30)
) as s(grp, code, label, delta, mins, sort)
on conflict (id) do nothing;

-- Workflow routes with standard minutes. These are placeholder estimates: the
-- Product Owner's own figures are decision 6 in the blueprint, and the engine
-- recalibrates from actual task durations once real work flows through.
insert into workflow_template (id, business_id, garment_type_id, version, is_current, note)
select md5('wtpl:' || g.code)::uuid, md5('business:dhaaga-dev')::uuid, md5('gtype:' || g.code)::uuid, 1, true,
       'Placeholder standard minutes pending the owner''s estimates (decision 6)'
from (values ('SHIRT'),('TROUSER'),('KURTA'),('BLOUSE'),('BLAZER')) as g(code)
on conflict (id) do nothing;

insert into workflow_stage (id, business_id, template_id, code, label, sequence_no, standard_minutes, is_wage_bearing, requires_qc)
select md5('wstage:' || w.gtype || ':' || w.code)::uuid, md5('business:dhaaga-dev')::uuid,
       md5('wtpl:' || w.gtype)::uuid, w.code, w.label, w.seq, w.mins, w.wage, w.qc
from (values
 ('SHIRT','CUT','Cutting',1,25,true,false),   ('SHIRT','STITCH','Stitching',2,180,true,false),
 ('SHIRT','FINISH','Finishing',3,35,true,false), ('SHIRT','QC','Quality check',4,10,false,true),
 ('TROUSER','CUT','Cutting',1,20,true,false), ('TROUSER','STITCH','Stitching',2,150,true,false),
 ('TROUSER','FINISH','Finishing',3,30,true,false), ('TROUSER','QC','Quality check',4,10,false,true),
 ('KURTA','CUT','Cutting',1,25,true,false),   ('KURTA','STITCH','Stitching',2,160,true,false),
 ('KURTA','FINISH','Finishing',3,30,true,false), ('KURTA','QC','Quality check',4,10,false,true),
 ('BLOUSE','CUT','Cutting',1,30,true,false),  ('BLOUSE','STITCH','Stitching',2,200,true,false),
 ('BLOUSE','FINISH','Finishing',3,40,true,false), ('BLOUSE','QC','Quality check',4,15,false,true),
 ('BLAZER','CUT','Cutting',1,60,true,false),  ('BLAZER','STITCH','Stitching',2,600,true,false),
 ('BLAZER','FINISH','Finishing',3,90,true,false), ('BLAZER','QC','Quality check',4,20,false,true)
) as w(gtype, code, label, seq, mins, wage, qc)
on conflict (id) do nothing;

-- ===========================================================================
-- Capacity: working week and staff
-- ===========================================================================
insert into branch_calendar (id, business_id, branch_id, weekday, is_working, opens_at, closes_at)
select md5('cal:main:' || d.wd::text)::uuid, md5('business:dhaaga-dev')::uuid, md5('branch:main')::uuid,
       d.wd, d.working, case when d.working then time '10:00' end, case when d.working then time '20:00' end
from (values (0,false),(1,true),(2,true),(3,true),(4,true),(5,true),(6,true)) as d(wd, working)
on conflict (id) do nothing;

insert into staff_capacity (id, business_id, branch_id, user_id, minutes_per_day, efficiency_factor, effective_from)
select md5('cap:' || u.key)::uuid, md5('business:dhaaga-dev')::uuid, md5('branch:main')::uuid,
       md5('user:' || u.key)::uuid, u.mins, u.eff, date '2026-04-01'
from (values ('tailor1',480,1.00),('tailor2',480,0.90),('cutter',480,1.10)) as u(key, mins, eff)
on conflict (id) do nothing;

insert into staff_skill (id, business_id, user_id, garment_type_id, skill_level, is_eligible)
select md5('skill:' || s.ukey || ':' || s.gtype)::uuid, md5('business:dhaaga-dev')::uuid,
       md5('user:' || s.ukey)::uuid, md5('gtype:' || s.gtype)::uuid, s.lvl, true
from (values
 ('tailor1','SHIRT',5),('tailor1','TROUSER',4),('tailor1','BLAZER',3),
 ('tailor2','KURTA',5),('tailor2','BLOUSE',5),('tailor2','SHIRT',3)
) as s(ukey, gtype, lvl)
on conflict (id) do nothing;

-- ===========================================================================
-- Pricing and tax
-- ===========================================================================
insert into price_list (id, business_id, code, name, pricing_mode, is_default, effective_from)
values (md5('plist:standard')::uuid, md5('business:dhaaga-dev')::uuid, 'STD', 'Standard', 'exclusive', true, date '2026-04-01')
on conflict (id) do nothing;

-- Tax codes and rates are PLACEHOLDERS. Nothing here is advice, and no invoice
-- may be issued against them in production until a CA sign-off exists (BR-22).
insert into tax_code (id, business_id, code, kind, hsn_sac, description) values
 (md5('taxcode:STITCHING')::uuid, md5('business:dhaaga-dev')::uuid, 'STITCHING', 'service', '998821',
  'PLACEHOLDER - tailoring service. Rate and SAC to be confirmed by a CA (BR-22).'),
 (md5('taxcode:FABRIC')::uuid,    md5('business:dhaaga-dev')::uuid, 'FABRIC',    'goods',   null,
  'PLACEHOLDER - fabric sold from stock. Rate and HSN to be confirmed by a CA (BR-22).')
on conflict (id) do nothing;

insert into price_list_item (id, business_id, price_list_id, garment_type_id, unit_price, tax_code_id)
select md5('plitem:' || p.gtype)::uuid, md5('business:dhaaga-dev')::uuid, md5('plist:standard')::uuid,
       md5('gtype:' || p.gtype)::uuid, p.price, md5('taxcode:STITCHING')::uuid
from (values ('SHIRT',600),('TROUSER',900),('KURTA',800),('BLOUSE',700),('BLAZER',3500)) as p(gtype, price)
on conflict (id) do nothing;

-- ===========================================================================
-- Document number series
-- ===========================================================================
insert into number_series (id, business_id, branch_id, doc_type, financial_year, prefix, padding, is_offline_leasable)
select md5('series:' || s.doc || ':2026-27')::uuid, md5('business:dhaaga-dev')::uuid, md5('branch:main')::uuid,
       s.doc, '2026-27', s.prefix, 5, s.leasable
from (values
 -- Order tokens and job cards are leased to devices so an offline print is
 -- final. Tax invoices are never leased: their register must have no
 -- unexplained holes (§5.3).
 ('order_token',   'BR1-',     true),
 ('job_card',      'JC-',      true),
 ('delivery_note', 'DN-',      true),
 ('tax_invoice',   'INV/26-27/', false),
 ('credit_note',   'CN/26-27/',  false),
 ('payment_receipt','RCP-',    false)
) as s(doc, prefix, leasable)
on conflict (id) do nothing;

-- ===========================================================================
-- Configuration registry defaults (AP-1 / BR-21)
-- ===========================================================================
insert into config_setting (id, business_id, key, category, scope, value_type, default_value, current_value,
                            required_permission, is_effective_dated, is_ca_validated_scope, description)
select md5('config:' || c.key)::uuid, md5('business:dhaaga-dev')::uuid, c.key, c.category, c.scope,
       c.vtype, c.dflt::jsonb, c.dflt::jsonb, c.perm, c.dated, c.ca, c.descr
from (values
 ('finance.revenue_recognition_point','finance','business','enum','"on_delivery"','config.tax.manage',true,true,
  'When a garment becomes revenue. Default on delivery; must be confirmed by a CA (BR-02, BR-22).'),
 ('finance.collection_policy','finance','business','enum','"on_delivery"','config.manage',false,false,
  'Whether the balance for delivered pieces must be cleared at handover.'),
 ('finance.invoice_per_delivery','finance','business','boolean','true','config.tax.manage',false,true,
  'One tax invoice per delivery, rather than one at completion. Subject to CA confirmation.'),
 ('finance.cash_difference_tolerance','finance','branch','decimal','10','config.manage',false,false,
  'Rupee difference at day close below which no explanation is demanded.'),
 ('production.rework_reserve_percent','production','branch','decimal','12','config.production.manage',true,false,
  'Share of daily capacity held back for alterations (§6).'),
 ('production.promise_buffer_days','production','branch','integer','1','config.production.manage',false,false,
  'Buffer added to the calculated completion date before it is promised.'),
 ('production.capacity_unit','production','business','enum','"standard_minutes"','config.production.manage',false,false,
  'The unit the capacity engine schedules in.'),
 ('customer.duplicate_review_threshold','customer','business','decimal','0.80','config.manage',false,false,
  'Score at or above which a candidate pair is queued for human review (§2.3).'),
 ('customer.dormancy_days','customer','business','integer','270','config.manage',false,false,
  'Days without an order after which a customer counts as dormant.'),
 ('offline.warn_after_hours','offline','business','integer','48','config.manage',false,false,
  'Unsynced duration after which a device shows the offline-too-long state (§5.4).'),
 ('offline.token_lease_size','offline','business','integer','100','config.manage',false,false,
  'How many document numbers a device leases at a time (§5.3).'),
 ('ux.order_creation_target_seconds','ux','business','integer','180','config.manage',false,false,
  'The order-creation budget the app measures itself against (§7).')
) as c(key, category, scope, vtype, dflt, perm, dated, ca, descr)
on conflict (id) do nothing;

-- ===========================================================================
-- Which changes demand a reason (BR-13, WP-4)
-- ===========================================================================
-- Configuration, not a constant: the owner decides what must be justified.
-- Narrowed to specific columns where a blanket rule would demand a reason for
-- correcting a spelling.
insert into audit_reason_requirement (id, business_id, entity_type, action, column_name, note)
select md5('reasonreq:' || r.entity || ':' || r.action || ':' || coalesce(r.col, '*'))::uuid,
       md5('business:dhaaga-dev')::uuid, r.entity, r.action, r.col, r.note
from (values
 ('order_item',       'update', 'unit_price',              'A price override must say why'),
 ('order_item',       'update', 'discount_amount',         'Discounts are measurable leakage (BR-20)'),
 ('sales_order',      'update', 'lifecycle',               'Cancelling an order needs a reason'),
 ('garment',          'update', 'measurement_snapshot_id', 'Changing what a garment is cut to (BR-01)'),
 ('payment',          'update', 'status',                  'Reversing a payment'),
 ('wage_entry',       'update', 'amount',                  'Adjusting what someone earned'),
 ('user_branch_role', 'update', 'revoked_at',              'Removing a person''s access'),
 ('role_permission',  'delete', null,                      'Removing a permission from a role'),
 ('config_setting',   'update', 'current_value',           'Changing a business rule'),
 ('tax_rate',         'any',    null,                      'Any change to tax configuration (BR-22)'),
 ('validation_signoff','any',   null,                      'Recording or superseding a CA sign-off'),
 ('customer_merge',   'insert', null,                      'Merging two customer records'),
 ('customer_material','update', 'status',                  'Writing off cloth that belongs to a customer')
) as r(entity, action, col, note)
on conflict (id) do nothing;
