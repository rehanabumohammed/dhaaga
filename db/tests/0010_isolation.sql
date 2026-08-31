-- WP-3 isolation suite.
--
-- The point of these assertions is not that the application behaves well. It is
-- that the DATABASE refuses, so a bug in a query, a misconfigured client, or a
-- direct REST call with the publishable key cannot reach another branch's or
-- another business's rows (AP-5, BR-17).
--
-- Every check runs as the `authenticated` role, which is what Supabase's REST
-- layer connects as. Running them as the owner would prove nothing: a table
-- owner bypasses row-level security, and a suite that tests the wrong role is
-- worse than no suite because it produces false confidence.

-- ---------------------------------------------------------------------------
-- Coverage first: no table may be left unprotected
-- ---------------------------------------------------------------------------
select dhaaga_test.eq(
    coalesce((select string_agg(c.relname, ', ' order by c.relname)
              from pg_class c join pg_namespace n on n.oid = c.relnamespace
              where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity), ''),
    '', 'every table has row-level security enabled');

select dhaaga_test.eq(
    coalesce((select string_agg(c.relname, ', ' order by c.relname)
              from pg_class c join pg_namespace n on n.oid = c.relnamespace
              where n.nspname = 'public' and c.relkind = 'r'
                and not exists (select 1 from pg_policy p where p.polrelid = c.oid)), ''),
    '', 'every table carries at least one policy - RLS with no policy denies everything, which is a different bug');

select dhaaga_test.eq(
    (select count(*)::int from information_schema.role_table_grants
     where grantee = 'anon' and table_schema = 'public'),
    0, 'the anonymous role holds no privilege on any table - this product has no anonymous surface');

-- Views are the quiet way through row-level security. A view runs with its
-- OWNER's rights unless it says otherwise, so a view over protected tables is a
-- hole straight past every policy beneath it - and the table-coverage checks
-- above will never notice, because a view is not a table. Found while adding
-- the trial balance in WP-5.
select dhaaga_test.eq(
    coalesce((select string_agg(c.relname, ', ' order by c.relname)
              from pg_class c join pg_namespace n on n.oid = c.relnamespace
              where n.nspname = 'public' and c.relkind = 'v'
                and coalesce(array_to_string(c.reloptions, ','), '') not like '%security_invoker=true%'), ''),
    '', 'every view runs with the caller''s privileges, not its owner''s');

select dhaaga_test.eq(
    coalesce((select string_agg(privilege_type, ', ' order by privilege_type)
              from information_schema.role_table_grants
              where grantee = 'authenticated' and table_schema = 'public'
                and table_name = 'audit_event'), ''),
    'INSERT, SELECT',
    'the audit trail is insert-and-read only for application callers (BR-13)');

-- ---------------------------------------------------------------------------
-- Two businesses, three branches, three users
-- ---------------------------------------------------------------------------
insert into business (id, legal_name) values
 ('aaaa0000-0000-0000-0000-000000000001', 'Business A'),
 ('bbbb0000-0000-0000-0000-000000000001', 'Business B');

insert into branch (id, business_id, code, name) values
 ('a1110000-0000-0000-0000-000000000001', 'aaaa0000-0000-0000-0000-000000000001', 'A1', 'A branch one'),
 ('a2220000-0000-0000-0000-000000000001', 'aaaa0000-0000-0000-0000-000000000001', 'A2', 'A branch two'),
 ('b1110000-0000-0000-0000-000000000001', 'bbbb0000-0000-0000-0000-000000000001', 'B1', 'B branch one');

-- WP-7: the token carries a Supabase Auth subject, which is a DIFFERENT value
-- from the application user's id. Fixtures derive one deterministically so the
-- distinction is exercised on every case rather than accidentally collapsed.
insert into app_user (id, business_id, auth_user_id, full_name) values
 ('11110000-0000-0000-0000-00000000000a', 'aaaa0000-0000-0000-0000-000000000001',
  md5('auth:11110000-0000-0000-0000-00000000000a')::uuid, 'A user, branch one only'),
 ('22220000-0000-0000-0000-00000000000a', 'aaaa0000-0000-0000-0000-000000000001',
  md5('auth:22220000-0000-0000-0000-00000000000a')::uuid, 'A user, both branches'),
 ('33330000-0000-0000-0000-00000000000b', 'bbbb0000-0000-0000-0000-000000000001',
  md5('auth:33330000-0000-0000-0000-00000000000b')::uuid, 'B user');

insert into role (id, business_id, code, name) values
 ('90000000-0000-0000-0000-00000000000a', 'aaaa0000-0000-0000-0000-000000000001', 'staff', 'Staff'),
 ('90000000-0000-0000-0000-00000000000b', 'bbbb0000-0000-0000-0000-000000000001', 'staff', 'Staff');

insert into user_branch_role (business_id, user_id, branch_id, role_id) values
 ('aaaa0000-0000-0000-0000-000000000001', '11110000-0000-0000-0000-00000000000a', 'a1110000-0000-0000-0000-000000000001', '90000000-0000-0000-0000-00000000000a'),
 ('aaaa0000-0000-0000-0000-000000000001', '22220000-0000-0000-0000-00000000000a', 'a1110000-0000-0000-0000-000000000001', '90000000-0000-0000-0000-00000000000a'),
 ('aaaa0000-0000-0000-0000-000000000001', '22220000-0000-0000-0000-00000000000a', 'a2220000-0000-0000-0000-000000000001', '90000000-0000-0000-0000-00000000000a'),
 ('bbbb0000-0000-0000-0000-000000000001', '33330000-0000-0000-0000-00000000000b', 'b1110000-0000-0000-0000-000000000001', '90000000-0000-0000-0000-00000000000b');

insert into customer (id, business_id, display_name) values
 ('c0000000-0000-0000-0000-00000000000a', 'aaaa0000-0000-0000-0000-000000000001', 'Customer of A'),
 ('c0000000-0000-0000-0000-00000000000b', 'bbbb0000-0000-0000-0000-000000000001', 'Customer of B');

insert into sales_order (id, business_id, branch_id, order_no, customer_id) values
 ('e0000000-0000-0000-0000-0000000000a1', 'aaaa0000-0000-0000-0000-000000000001', 'a1110000-0000-0000-0000-000000000001', 'A1-001', 'c0000000-0000-0000-0000-00000000000a'),
 ('e0000000-0000-0000-0000-0000000000a2', 'aaaa0000-0000-0000-0000-000000000001', 'a2220000-0000-0000-0000-000000000001', 'A2-001', 'c0000000-0000-0000-0000-00000000000a'),
 ('e0000000-0000-0000-0000-0000000000b1', 'bbbb0000-0000-0000-0000-000000000001', 'b1110000-0000-0000-0000-000000000001', 'B1-001', 'c0000000-0000-0000-0000-00000000000b');

-- A helper so each case reads as "become this person, then look".
create or replace function pg_temp.become(user_id uuid)
returns void language plpgsql as $fn$
begin
    perform set_config('app.actor_id', '', true);
    -- The subject in a token is an auth identity, never an app_user id. The
    -- fixtures above assign each person one by the same rule, so this needs no
    -- lookup - which matters, because a lookup here would run under whichever
    -- identity the previous case left behind.
    perform set_config('request.jwt.claims',
                       json_build_object('sub', (md5('auth:' || user_id::text)::uuid)::text,
                                         'role', 'authenticated')::text,
                       true);
end $fn$;

-- ---------------------------------------------------------------------------
-- Business isolation
-- ---------------------------------------------------------------------------
select pg_temp.become('11110000-0000-0000-0000-00000000000a');
set local role authenticated;

select dhaaga_test.eq(
    (select count(*)::int from customer where id = 'c0000000-0000-0000-0000-00000000000b'), 0,
    'a user of business A cannot see a customer of business B');

select dhaaga_test.eq(
    (select count(*)::int from sales_order where business_id = 'bbbb0000-0000-0000-0000-000000000001'), 0,
    'nor any of business B''s orders');

select dhaaga_test.eq(
    (select count(*)::int from customer where id = 'c0000000-0000-0000-0000-00000000000a'), 1,
    'but sees their own business''s customers - customers are business-scoped by design');

-- Writing across the tenant boundary is refused outright, not silently ignored.
select dhaaga_test.throws(
    $$insert into customer (business_id, display_name)
      values ('bbbb0000-0000-0000-0000-000000000001', 'Planted in B')$$,
    'a user of A cannot create a row inside business B', '42501');

-- A data-modifying statement has to sit in a CTE to be counted; the point is
-- the row count, because row-level security makes the row not exist for this
-- caller rather than raising.
with attempted as (
    update customer set display_name = 'Renamed by A'
    where id = 'c0000000-0000-0000-0000-00000000000b' returning 1)
select dhaaga_test.eq((select count(*)::int from attempted), 0,
    'an update aimed at business B''s customer touches nothing - the row does not exist for this caller');

with attempted as (
    delete from customer where id = 'c0000000-0000-0000-0000-00000000000b' returning 1)
select dhaaga_test.eq((select count(*)::int from attempted), 0,
    'and neither does a delete');

-- ---------------------------------------------------------------------------
-- Branch isolation, inside one business
-- ---------------------------------------------------------------------------
select dhaaga_test.eq(
    (select count(*)::int from sales_order where id = 'e0000000-0000-0000-0000-0000000000a1'), 1,
    'a user granted branch A1 sees A1''s orders');

select dhaaga_test.eq(
    (select count(*)::int from sales_order where id = 'e0000000-0000-0000-0000-0000000000a2'), 0,
    'and does not see branch A2''s orders, though both belong to their own business (BR-17)');

select dhaaga_test.throws(
    $$insert into sales_order (business_id, branch_id, order_no, customer_id)
      values ('aaaa0000-0000-0000-0000-000000000001', 'a2220000-0000-0000-0000-000000000001',
              'A2-002', 'c0000000-0000-0000-0000-00000000000a')$$,
    'nor can they book an order into a branch they are not granted', '42501');

with attempted as (
    update sales_order set notes = 'touched'
    where id = 'e0000000-0000-0000-0000-0000000000a2' returning 1)
select dhaaga_test.eq((select count(*)::int from attempted), 0,
    'an update aimed at the other branch''s order touches nothing');

reset role;

-- A user granted both branches sees both. Isolation is a grant, not a wall.
select pg_temp.become('22220000-0000-0000-0000-00000000000a');
set local role authenticated;

select dhaaga_test.eq(
    (select count(*)::int from sales_order where business_id = 'aaaa0000-0000-0000-0000-000000000001'), 2,
    'a manager granted both branches sees both - one login covering two outlets');

reset role;

-- ---------------------------------------------------------------------------
-- The other direction
-- ---------------------------------------------------------------------------
select pg_temp.become('33330000-0000-0000-0000-00000000000b');
set local role authenticated;

select dhaaga_test.eq(
    (select count(*)::int from customer where business_id = 'aaaa0000-0000-0000-0000-000000000001'), 0,
    'a user of business B sees none of business A''s customers');

select dhaaga_test.eq(
    (select count(*)::int from business), 1,
    'and sees exactly one business: their own');

select dhaaga_test.eq(
    (select legal_name from business), 'Business B',
    'and it is the right one');

reset role;

-- ---------------------------------------------------------------------------
-- Revocation takes effect on the next action
-- ---------------------------------------------------------------------------
select dhaaga_test.as_nobody();
update user_branch_role set revoked_at = now()
where user_id = '11110000-0000-0000-0000-00000000000a';

select pg_temp.become('11110000-0000-0000-0000-00000000000a');
set local role authenticated;

select dhaaga_test.eq(
    (select count(*)::int from sales_order), 0,
    'a revoked branch grant removes access immediately, with no session to expire');

reset role;

-- ---------------------------------------------------------------------------
-- An unknown caller reaches nothing
-- ---------------------------------------------------------------------------
select pg_temp.become('00000000-0000-0000-0000-0000000000ff');
set local role authenticated;

select dhaaga_test.eq(
    (select count(*)::int from customer), 0,
    'a token for a user that does not exist reaches no rows at all');

select dhaaga_test.eq(
    (select count(*)::int from sales_order), 0,
    'and no orders');

reset role;

-- With no session context whatsoever - the shape of a raw call carrying only a
-- publishable key and no signed-in user.
select set_config('request.jwt.claims', '', true);
set local role authenticated;

select dhaaga_test.eq(
    (select count(*)::int from customer), 0,
    'a call with no identity at all - a bare publishable key - reaches nothing');

select dhaaga_test.eq(
    (select count(*)::int from garment), 0,
    'including production data');

select dhaaga_test.throws(
    $$insert into customer (business_id, display_name)
      values ('aaaa0000-0000-0000-0000-000000000001', 'Anonymous insert')$$,
    'and cannot write', '42501');

-- ---------------------------------------------------------------------------
-- The audit trail cannot be rewritten (BR-13)
-- ---------------------------------------------------------------------------
select dhaaga_test.throws(
    $$update audit_event set action = 'other'$$,
    'an application caller cannot modify an audit row', '42501');

select dhaaga_test.throws(
    $$delete from audit_event$$,
    'nor delete one', '42501');

reset role;
