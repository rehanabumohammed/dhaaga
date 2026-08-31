-- WP-5 audit regression tests.
--
-- Every assertion here corresponds to a defect that was REPRODUCED against the
-- database before migration 0013 was written. They are regression tests in the
-- literal sense: each one failed first.

insert into business (id, legal_name) values
 ('aaaa1111-0000-0000-0000-000000000001', 'Business A'),
 ('bbbb1111-0000-0000-0000-000000000001', 'Business B');
insert into branch (id, business_id, code, name) values
 ('aaaa1111-0000-0000-0000-000000000002', 'aaaa1111-0000-0000-0000-000000000001', 'A1', 'A granted'),
 ('aaaa1111-0000-0000-0000-00000000000f', 'aaaa1111-0000-0000-0000-000000000001', 'A2', 'A not granted'),
 ('bbbb1111-0000-0000-0000-000000000002', 'bbbb1111-0000-0000-0000-000000000001', 'B1', 'B one');
-- WP-7: the token subject is an auth identity, deliberately not the app_user
-- id, so a resolver that confuses the two fails here.
insert into app_user (id, business_id, auth_user_id, full_name) values
 ('aaaa1111-0000-0000-0000-000000000003', 'aaaa1111-0000-0000-0000-000000000001',
  md5('auth:aaaa1111-0000-0000-0000-000000000003')::uuid, 'User A'),
 ('bbbb1111-0000-0000-0000-000000000003', 'bbbb1111-0000-0000-0000-000000000001',
  md5('auth:bbbb1111-0000-0000-0000-000000000003')::uuid, 'User B');
insert into role (id, business_id, code, name) values
 ('aaaa1111-0000-0000-0000-000000000004', 'aaaa1111-0000-0000-0000-000000000001', 'staff', 'Staff'),
 ('bbbb1111-0000-0000-0000-000000000004', 'bbbb1111-0000-0000-0000-000000000001', 'staff', 'Staff');
insert into user_branch_role (business_id, user_id, branch_id, role_id) values
 ('aaaa1111-0000-0000-0000-000000000001','aaaa1111-0000-0000-0000-000000000003','aaaa1111-0000-0000-0000-000000000002','aaaa1111-0000-0000-0000-000000000004'),
 ('bbbb1111-0000-0000-0000-000000000001','bbbb1111-0000-0000-0000-000000000003','bbbb1111-0000-0000-0000-000000000002','bbbb1111-0000-0000-0000-000000000004');
insert into account (id, business_id, code, name, account_type, normal_balance) values
 ('aaaa1111-0000-0000-0000-00000000000a','aaaa1111-0000-0000-0000-000000000001','1100','A Cash','asset','debit'),
 ('aaaa1111-0000-0000-0000-00000000000b','aaaa1111-0000-0000-0000-000000000001','4100','A Sales','revenue','credit'),
 ('bbbb1111-0000-0000-0000-00000000000a','bbbb1111-0000-0000-0000-000000000001','1100','B Cash','asset','debit'),
 ('bbbb1111-0000-0000-0000-00000000000b','bbbb1111-0000-0000-0000-000000000001','4100','B Sales','revenue','credit');
insert into customer (id, business_id, display_name) values
 ('bbbb1111-0000-0000-0000-00000000000c','bbbb1111-0000-0000-0000-000000000001','B confidential customer');

-- Business B posts a private entry, and one to be a reversal target.
select app.post_entry('bbbb1111-0000-0000-0000-000000000001','bbbb1111-0000-0000-0000-000000000002',
    'payment', null, 'B private entry',
    jsonb_build_array(jsonb_build_object('account_id','bbbb1111-0000-0000-0000-00000000000a','debit',5000),
                      jsonb_build_object('account_id','bbbb1111-0000-0000-0000-00000000000b','credit',5000)));
set constraints all immediate;
set constraints all deferred;

-- ===========================================================================
-- AREA 1 · SECURITY DEFINER hardening
-- ===========================================================================
select dhaaga_test.eq(
    coalesce((select string_agg(p.proname, ', ' order by p.proname)
              from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'app' and p.prosecdef
                and (p.proconfig is null
                     or not exists (select 1 from unnest(p.proconfig) c where c like 'search_path=%'))), ''),
    '', 'every SECURITY DEFINER function pins its search_path');

select dhaaga_test.eq(
    coalesce((select string_agg(p.proname, ', ' order by p.proname)
              from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'app' and p.prosecdef
                and has_function_privilege('public', p.oid, 'EXECUTE')), ''),
    '', 'no SECURITY DEFINER function is executable by PUBLIC');

select dhaaga_test.eq(
    coalesce((select string_agg(p.proname, ', ' order by p.proname)
              from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'app' and has_function_privilege('anon', p.oid, 'EXECUTE')), ''),
    '', 'and none is executable by the anonymous role');

-- Those two assertions are the only control there is, and it matters that they
-- run: PostgreSQL grants EXECUTE on every new function to PUBLIC, and that
-- default CANNOT be revoked (see the note in migration 0014). A function
-- created below demonstrates the exposure this suite exists to catch - it is
-- expected to be PUBLIC-executable, which is precisely why every migration must
-- revoke explicitly and why the two assertions above are load-bearing.
create function app.default_privilege_demo() returns integer language sql as $probe$ select 1 $probe$;
select dhaaga_test.eq(
    has_function_privilege('public', 'app.default_privilege_demo()', 'EXECUTE'),
    true,
    'a new function IS PUBLIC-executable by default - the exposure is real, and the assertions above are what stop it shipping');
drop function app.default_privilege_demo();

select dhaaga_test.eq(
    has_function_privilege('authenticated', 'app.post_entry(uuid,uuid,text,uuid,text,jsonb,date)', 'EXECUTE'),
    false, 'application users cannot post to the ledger directly - domain services do that (AP-2)');

select dhaaga_test.eq(
    has_function_privilege('authenticated', 'app.reverse_journal_entry(uuid,text,text,date)', 'EXECUTE'),
    false, 'nor reverse an entry directly');

select dhaaga_test.eq(
    has_function_privilege('authenticated', 'app.set_context(uuid,uuid,text,text)', 'EXECUTE'),
    false, 'nor call the function that can name an actor');

select dhaaga_test.eq(
    has_function_privilege('authenticated', 'app.set_request_context(uuid,text,text)', 'EXECUTE'),
    true, 'but they can supply a device and a reason, which names no identity');

-- ---------------------------------------------------------------------------
-- The critical one: identity cannot be reassigned by the caller
-- ---------------------------------------------------------------------------
-- Before migration 0013 this sequence made user A into user B for every policy
-- in the database, and A could then read B's customers. Reproduced.
select set_config('request.jwt.claims',
    json_build_object('sub',(md5('auth:aaaa1111-0000-0000-0000-000000000003')::uuid)::text,'role','authenticated')::text, true);

select dhaaga_test.eq(
    app.current_user_id(), 'aaaa1111-0000-0000-0000-000000000003'::uuid,
    'a verified token identifies the caller');

select set_config('app.actor_id', 'bbbb1111-0000-0000-0000-000000000003', true);

select dhaaga_test.eq(
    app.current_user_id(), 'aaaa1111-0000-0000-0000-000000000003'::uuid,
    'setting app.actor_id CANNOT displace a verified token - the bypass is closed');

select dhaaga_test.eq(
    app.current_business_id(), 'aaaa1111-0000-0000-0000-000000000001'::uuid,
    'so the caller''s tenant is still their own, not the one they named');

-- The override still works where it was meant to: no token at all.
select set_config('request.jwt.claims', '', true);
select dhaaga_test.eq(
    app.current_user_id(), 'bbbb1111-0000-0000-0000-000000000003'::uuid,
    'with no token, the server-side override applies as designed');

-- ---------------------------------------------------------------------------
-- SECURITY DEFINER functions re-assert the boundary they bypass
-- ---------------------------------------------------------------------------
select set_config('app.actor_id', '', true);
select set_config('request.jwt.claims',
    json_build_object('sub',(md5('auth:aaaa1111-0000-0000-0000-000000000003')::uuid)::text,'role','authenticated')::text, true);

select dhaaga_test.throws(
    $$select app.post_entry('bbbb1111-0000-0000-0000-000000000001','bbbb1111-0000-0000-0000-000000000002',
        'manual_adjustment', null, 'Planted by A',
        jsonb_build_array(jsonb_build_object('account_id','bbbb1111-0000-0000-0000-00000000000a','debit',9999),
                          jsonb_build_object('account_id','bbbb1111-0000-0000-0000-00000000000b','credit',9999)))$$,
    'a user of A cannot post a ledger entry into business B', '42501');

select dhaaga_test.throws(
    $$select app.post_entry('aaaa1111-0000-0000-0000-000000000001','aaaa1111-0000-0000-0000-00000000000f',
        'manual_adjustment', null, 'Planted into an ungranted branch',
        jsonb_build_array(jsonb_build_object('account_id','aaaa1111-0000-0000-0000-00000000000a','debit',9999),
                          jsonb_build_object('account_id','aaaa1111-0000-0000-0000-00000000000b','credit',9999)))$$,
    'nor into a branch of their own business that they hold no grant for', '42501');

select dhaaga_test.throws(
    $$select app.post_entry('aaaa1111-0000-0000-0000-000000000001','aaaa1111-0000-0000-0000-000000000002',
        'manual_adjustment', null, 'Foreign account',
        jsonb_build_array(jsonb_build_object('account_id','bbbb1111-0000-0000-0000-00000000000a','debit',10),
                          jsonb_build_object('account_id','aaaa1111-0000-0000-0000-00000000000b','credit',10)))$$,
    'nor reference another business''s account from an otherwise valid entry', '42501');

-- Knowing an entry id is not authority to reverse it.
select dhaaga_test.throws(
    format($$select app.reverse_journal_entry(%L, 'malicious')$$,
           (select id from journal_entry where memo = 'B private entry')),
    'knowing another business''s entry id does not permit reversing it', '42501');

select dhaaga_test.lives(
    $$select app.post_entry('aaaa1111-0000-0000-0000-000000000001','aaaa1111-0000-0000-0000-000000000002',
        'payment', null, 'A legitimate entry',
        jsonb_build_array(jsonb_build_object('account_id','aaaa1111-0000-0000-0000-00000000000a','debit',100),
                          jsonb_build_object('account_id','aaaa1111-0000-0000-0000-00000000000b','credit',100)));
      set constraints all immediate; set constraints all deferred$$,
    'while a posting inside the caller''s own business and granted branch still works');

-- ===========================================================================
-- AREA 2 · Tenant isolation of the ledger, as authenticated
-- ===========================================================================
set local role authenticated;

select dhaaga_test.eq(
    (select count(*)::int from journal_entry where business_id = 'bbbb1111-0000-0000-0000-000000000001'),
    0, 'A cannot read B''s journal entries');

select dhaaga_test.eq(
    (select count(*)::int from journal_line where business_id = 'bbbb1111-0000-0000-0000-000000000001'),
    0, 'nor B''s journal lines');

select dhaaga_test.eq(
    (select count(*)::int from ledger_trial_balance where business_id = 'bbbb1111-0000-0000-0000-000000000001'),
    0, 'nor B''s ledger through the trial balance view');

select dhaaga_test.eq(
    (select count(*)::int from customer where business_id = 'bbbb1111-0000-0000-0000-000000000001'),
    0, 'nor B''s customers - the data the identity bypass exposed');

select dhaaga_test.ok(
    (select count(*) >= 1 from ledger_trial_balance
     where business_id = 'aaaa1111-0000-0000-0000-000000000001'),
    'while seeing their own business''s trial balance normally');

reset role;

insert into accounting_period (business_id, code, starts_on, ends_on)
values ('bbbb1111-0000-0000-0000-000000000001','2026-08','2026-08-01','2026-08-31');

set local role authenticated;
select dhaaga_test.eq(
    (select count(*)::int from accounting_period where business_id = 'bbbb1111-0000-0000-0000-000000000001'),
    0, 'nor B''s accounting periods');
reset role;

-- ===========================================================================
-- AREA 4 · Money and rounding
-- ===========================================================================
select dhaaga_test.eq(
    (select format_type(t.typbasetype, t.typtypmod) from pg_type t
     join pg_namespace n on n.oid = t.typnamespace
     where n.nspname = 'app' and t.typname = 'money_amount'),
    'numeric(14,2)', 'money is exact decimal at two places, never floating point');

-- Money columns mostly use the app.money_amount domain, and format_type()
-- reports a domain by its own name rather than its base type - so a naive check
-- flags every correctly-typed column. Resolve the domain first. (This caught a
-- bug in the assertion, not in the schema.)
select dhaaga_test.eq(
    coalesce((with money_cols as (
        select c.relname, a.attname,
               case when t.typtype = 'd' then bt.typname else t.typname end as base_type
        from pg_class c
        join pg_namespace n on n.oid = c.relnamespace
        join pg_attribute a on a.attrelid = c.oid
        join pg_type t on t.oid = a.atttypid
        left join pg_type bt on bt.oid = t.typbasetype
        where n.nspname = 'public' and c.relkind = 'r'
          and a.attnum > 0 and not a.attisdropped
          and a.attname not like '%\_id'
          and (a.attname like '%amount%' or a.attname like '%price%'
               or a.attname like '%cost%' or a.attname like '%rate%'
               or a.attname in ('debit','credit'))
    ) select string_agg(relname || '.' || attname || ':' || base_type, ', ' order by relname, attname)
      from money_cols where base_type <> 'numeric'), ''),
    '', 'every monetary column resolves to numeric - no float, real or double anywhere near money');

-- Exactness, demonstrated against the classic floating-point failure.
select dhaaga_test.eq(
    (0.1::numeric + 0.2::numeric = 0.3::numeric), true,
    'decimal arithmetic is exact: 0.1 + 0.2 equals 0.3');

select dhaaga_test.eq(
    (0.1::double precision + 0.2::double precision = 0.3::double precision), false,
    'the same sum in floating point does not - which is why money is never float');

-- Rounding at the column boundary is deterministic: half away from zero.
select dhaaga_test.eq(
    (583.335::app.money_amount)::numeric, 583.34::numeric,
    'a third decimal rounds half away from zero, deterministically');

select dhaaga_test.eq(
    (583.334::app.money_amount)::numeric, 583.33::numeric,
    'and below the halfway point it rounds down');

-- The §4 allocation: three shares of 1750.00 that must sum back exactly.
select dhaaga_test.eq(
    (583.33::app.money_amount + 583.33::app.money_amount + 583.34::app.money_amount)::numeric,
    1750.00::numeric,
    'the three-way allocation sums back to the line exactly, to the paisa');

-- A one-paisa discrepancy must fail the balance check. This is the smallest
-- error the ledger could contain, and the one a float model would create.
select dhaaga_test.throws(
    $$select app.post_entry('aaaa1111-0000-0000-0000-000000000001','aaaa1111-0000-0000-0000-000000000002',
        'manual_adjustment', null, 'One paisa out',
        jsonb_build_array(jsonb_build_object('account_id','aaaa1111-0000-0000-0000-00000000000a','debit',100.01),
                          jsonb_build_object('account_id','aaaa1111-0000-0000-0000-00000000000b','credit',100.00)));
      set constraints all immediate$$,
    'an entry out by a single paisa is refused', '23514');

select dhaaga_test.lives(
    $$select app.post_entry('aaaa1111-0000-0000-0000-000000000001','aaaa1111-0000-0000-0000-000000000002',
        'manual_adjustment', null, 'Sub-rupee amounts',
        jsonb_build_array(jsonb_build_object('account_id','aaaa1111-0000-0000-0000-00000000000a','debit',0.01),
                          jsonb_build_object('account_id','aaaa1111-0000-0000-0000-00000000000b','credit',0.01)));
      set constraints all immediate; set constraints all deferred$$,
    'a one-paisa entry is valid: the smallest real amount still balances');

-- Rounding inside the sum, not after it: three lines that individually round.
select dhaaga_test.lives(
    $$select app.post_entry('aaaa1111-0000-0000-0000-000000000001','aaaa1111-0000-0000-0000-000000000002',
        'manual_adjustment', null, 'Rounded lines that must still balance',
        jsonb_build_array(jsonb_build_object('account_id','aaaa1111-0000-0000-0000-00000000000a','debit',33.335),
                          jsonb_build_object('account_id','aaaa1111-0000-0000-0000-00000000000b','credit',33.34)));
      set constraints all immediate; set constraints all deferred$$,
    'a line rounded at the column boundary balances against the value it rounds to');

select dhaaga_test.eq(
    (select sum(debit) - sum(credit) from journal_line
     where business_id = 'aaaa1111-0000-0000-0000-000000000001'),
    0::numeric, 'and the whole of business A''s ledger still nets to exactly zero');

-- ===========================================================================
-- AREA 4 · Audit integrity
-- ===========================================================================
-- Immutability and out-of-band capture are covered by 0012_audit.sql and are
-- not repeated here. These are the two properties the security gate adds:
-- a refused authorization must leave nothing behind, and a client must not be
-- able to put someone else's name on its own actions.

-- A refused cross-tenant posting must not have written anything first. The
-- boundary check runs before any insert, but "it should" is not evidence.
select dhaaga_test.eq(
    (select count(*)::int from journal_entry
     where business_id = 'bbbb1111-0000-0000-0000-000000000001'
       and memo like 'Planted%'),
    0, 'a refused cross-tenant posting leaves no journal entry behind');

select dhaaga_test.eq(
    (select count(*)::int from journal_line jl
     join journal_entry je on je.id = jl.entry_id
     where je.memo like 'Planted%'),
    0, 'and no journal lines');

select dhaaga_test.eq(
    (select coalesce(sum(debit) - sum(credit), 0) from journal_line
     where business_id = 'bbbb1111-0000-0000-0000-000000000001'),
    0::numeric, 'and business B''s ledger is untouched and still balanced');

-- Client-supplied identity must never reach the audit trail. With a token for
-- user A and app.actor_id naming user B, the recorded actor must be A.
select set_config('request.jwt.claims',
    json_build_object('sub',(md5('auth:aaaa1111-0000-0000-0000-000000000003')::uuid)::text,'role','authenticated')::text, true);
select set_config('app.actor_id', 'bbbb1111-0000-0000-0000-000000000003', true);

insert into customer (id, business_id, display_name)
values ('aaaa1111-0000-0000-0000-0000000000ff','aaaa1111-0000-0000-0000-000000000001','Attribution probe');

select dhaaga_test.eq(
    (select actor_user_id from audit_event
     where entity_type = 'customer' and entity_id = 'aaaa1111-0000-0000-0000-0000000000ff'),
    'aaaa1111-0000-0000-0000-000000000003'::uuid,
    'an audit row is attributed to the token subject, not to the identity the caller named');

select dhaaga_test.eq(
    (select count(*)::int from audit_event
     where actor_user_id = 'bbbb1111-0000-0000-0000-000000000003'),
    0, 'and the named identity appears nowhere in the audit trail');

select set_config('app.actor_id', '', true);
