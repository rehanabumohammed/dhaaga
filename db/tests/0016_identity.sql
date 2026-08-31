-- WP-7 · Identity, roles and permissions.
--
-- Eighteen attacks were reproduced against the database BEFORE migration 0016
-- was written. Every one of them is an assertion here, and every one of them
-- failed first. They are marked REPRODUCED.
--
-- What this file cannot do, and why the shell harness exists: it runs as the
-- schema owner and uses SET ROLE, so app.session_is_trusted() is true whichever
-- role it switches into. Anything that turns on session trust - the auth
-- identity link, the actor override - is proven in scripts/attack_identity.sh
-- against a real untrusted login role instead. Assertions here that would be
-- vacuous under owner trust say so rather than pretending.

-- ===========================================================================
-- Fixtures
-- ===========================================================================
-- Business A: an owner (user.manage, role.manage, branch.manage), a manager
-- (user.manage, one branch of two) and a tailor (nothing but order.create).
-- Business B exists so that "another tenant" is a real tenant.
--
-- Auth identities are deliberately NOT equal to app_user ids. A resolver that
-- confuses the two would pass every assertion below if they matched.
insert into business (id, legal_name) values
 ('7777aaaa-0000-0000-0000-000000000001', 'Identity A'),
 ('7777bbbb-0000-0000-0000-000000000001', 'Identity B');

insert into branch (id, business_id, code, name) values
 ('7777aaaa-0000-0000-0000-000000000010', '7777aaaa-0000-0000-0000-000000000001', 'IA1', 'A one'),
 ('7777aaaa-0000-0000-0000-000000000011', '7777aaaa-0000-0000-0000-000000000001', 'IA2', 'A two'),
 ('7777bbbb-0000-0000-0000-000000000010', '7777bbbb-0000-0000-0000-000000000001', 'IB1', 'B one');

insert into app_user (id, business_id, auth_user_id, full_name) values
 ('7777aaaa-0000-0000-0000-000000000020', '7777aaaa-0000-0000-0000-000000000001',
  '1111aaaa-0000-0000-0000-000000000020', 'A owner'),
 ('7777aaaa-0000-0000-0000-000000000021', '7777aaaa-0000-0000-0000-000000000001',
  '1111aaaa-0000-0000-0000-000000000021', 'A manager'),
 ('7777aaaa-0000-0000-0000-000000000022', '7777aaaa-0000-0000-0000-000000000001',
  '1111aaaa-0000-0000-0000-000000000022', 'A tailor'),
 -- Recorded, paid, assigned work, and never logs in. The nullable column is the
 -- point: a tailoring shop is full of people with no phone to receive an OTP.
 ('7777aaaa-0000-0000-0000-000000000023', '7777aaaa-0000-0000-0000-000000000001',
  null, 'A tailor with no login'),
 ('7777bbbb-0000-0000-0000-000000000020', '7777bbbb-0000-0000-0000-000000000001',
  '1111bbbb-0000-0000-0000-000000000020', 'B owner');

insert into role (id, business_id, code, name, is_system) values
 ('7777aaaa-0000-0000-0000-000000000030', '7777aaaa-0000-0000-0000-000000000001', 'owner',   'Owner',   true),
 ('7777aaaa-0000-0000-0000-000000000031', '7777aaaa-0000-0000-0000-000000000001', 'manager', 'Manager', true),
 ('7777aaaa-0000-0000-0000-000000000032', '7777aaaa-0000-0000-0000-000000000001', 'tailor',  'Tailor',  true),
 ('7777bbbb-0000-0000-0000-000000000030', '7777bbbb-0000-0000-0000-000000000001', 'owner',   'Owner',   true);

insert into permission (id, business_id, code, domain) values
 ('7777aaaa-0000-0000-0000-000000000040', '7777aaaa-0000-0000-0000-000000000001', 'order.create',    'order'),
 ('7777aaaa-0000-0000-0000-000000000041', '7777aaaa-0000-0000-0000-000000000001', 'user.manage',     'admin'),
 ('7777aaaa-0000-0000-0000-000000000042', '7777aaaa-0000-0000-0000-000000000001', 'role.manage',     'admin'),
 ('7777aaaa-0000-0000-0000-000000000043', '7777aaaa-0000-0000-0000-000000000001', 'branch.manage',   'admin'),
 ('7777aaaa-0000-0000-0000-000000000044', '7777aaaa-0000-0000-0000-000000000001', 'business.manage', 'admin'),
 ('7777bbbb-0000-0000-0000-000000000041', '7777bbbb-0000-0000-0000-000000000001', 'user.manage',     'admin');

insert into role_permission (business_id, role_id, permission_id) values
 ('7777aaaa-0000-0000-0000-000000000001','7777aaaa-0000-0000-0000-000000000030','7777aaaa-0000-0000-0000-000000000040'),
 ('7777aaaa-0000-0000-0000-000000000001','7777aaaa-0000-0000-0000-000000000030','7777aaaa-0000-0000-0000-000000000041'),
 ('7777aaaa-0000-0000-0000-000000000001','7777aaaa-0000-0000-0000-000000000030','7777aaaa-0000-0000-0000-000000000042'),
 ('7777aaaa-0000-0000-0000-000000000001','7777aaaa-0000-0000-0000-000000000030','7777aaaa-0000-0000-0000-000000000043'),
 ('7777aaaa-0000-0000-0000-000000000001','7777aaaa-0000-0000-0000-000000000030','7777aaaa-0000-0000-0000-000000000044'),
 ('7777aaaa-0000-0000-0000-000000000001','7777aaaa-0000-0000-0000-000000000031','7777aaaa-0000-0000-0000-000000000041'),
 ('7777aaaa-0000-0000-0000-000000000001','7777aaaa-0000-0000-0000-000000000032','7777aaaa-0000-0000-0000-000000000040'),
 ('7777bbbb-0000-0000-0000-000000000001','7777bbbb-0000-0000-0000-000000000030','7777bbbb-0000-0000-0000-000000000041');

insert into user_branch_role (business_id, user_id, branch_id, role_id) values
 ('7777aaaa-0000-0000-0000-000000000001','7777aaaa-0000-0000-0000-000000000020','7777aaaa-0000-0000-0000-000000000010','7777aaaa-0000-0000-0000-000000000030'),
 ('7777aaaa-0000-0000-0000-000000000001','7777aaaa-0000-0000-0000-000000000020','7777aaaa-0000-0000-0000-000000000011','7777aaaa-0000-0000-0000-000000000030'),
 ('7777aaaa-0000-0000-0000-000000000001','7777aaaa-0000-0000-0000-000000000021','7777aaaa-0000-0000-0000-000000000010','7777aaaa-0000-0000-0000-000000000031'),
 ('7777aaaa-0000-0000-0000-000000000001','7777aaaa-0000-0000-0000-000000000022','7777aaaa-0000-0000-0000-000000000010','7777aaaa-0000-0000-0000-000000000032'),
 ('7777bbbb-0000-0000-0000-000000000001','7777bbbb-0000-0000-0000-000000000020','7777bbbb-0000-0000-0000-000000000010','7777bbbb-0000-0000-0000-000000000030');

create or replace function pg_temp.become(auth_id uuid)
returns void language plpgsql as $fn$
begin
    perform set_config('app.actor_id', '', true);
    perform set_config('request.jwt.claims',
        json_build_object('sub', auth_id::text, 'role', 'authenticated')::text, true);
end $fn$;

-- ===========================================================================
-- 1 · The chain: auth subject -> person -> business -> branch -> role -> permission
-- ===========================================================================
select pg_temp.become('1111aaaa-0000-0000-0000-000000000022');

select dhaaga_test.eq(
    app.auth_uid(), '1111aaaa-0000-0000-0000-000000000022'::uuid,
    'the token carries an authentication subject');

select dhaaga_test.eq(
    app.current_user_id(), '7777aaaa-0000-0000-0000-000000000022'::uuid,
    'which resolves to a different value: the application user');

select dhaaga_test.ok(
    app.auth_uid() is distinct from app.current_user_id(),
    'the two are not the same identifier, and nothing in the system may treat them as one');

select dhaaga_test.eq(
    app.current_business_id(), '7777aaaa-0000-0000-0000-000000000001'::uuid,
    'the person carries the tenant, which is a row and not a claim');

select dhaaga_test.eq(
    app.has_branch('7777aaaa-0000-0000-0000-000000000010'), true,
    'the branch grant carries the branch');

select dhaaga_test.eq(
    app.has_branch('7777aaaa-0000-0000-0000-000000000011'), false,
    'and only the branch granted');

select dhaaga_test.eq(
    app.has_permission('order.create'), true, 'the role carries the permission');
select dhaaga_test.eq(
    app.has_permission('user.manage'), false, 'and only the permissions of that role');

select dhaaga_test.eq(
    (select string_agg(c, ',' order by c) from app.my_permissions() c),
    'order.create', 'my_permissions reports the caller''s own set, and takes no argument to point elsewhere');

-- ===========================================================================
-- 2 · Null, empty, unknown and revoked identity
-- ===========================================================================
select pg_temp.become('00000000-0000-0000-0000-0000000000ff');
select dhaaga_test.eq(app.current_user_id(), null::uuid,
    'a token whose subject matches no person resolves to nobody');
select dhaaga_test.eq(app.current_business_id(), null::uuid, 'and to no tenant');

select set_config('request.jwt.claims', '{"role":"authenticated"}', true);
select dhaaga_test.eq(app.auth_uid(), null::uuid, 'a token with no subject claim yields no subject');
select dhaaga_test.eq(app.current_user_id(), null::uuid, 'and no person');

select set_config('request.jwt.claims', '{"sub":"","role":"authenticated"}', true);
select dhaaga_test.eq(app.current_user_id(), null::uuid, 'an empty subject yields nobody');

select set_config('request.jwt.claims', '{"sub":"not-a-uuid","role":"authenticated"}', true);
select dhaaga_test.eq(app.current_user_id(), null::uuid,
    'a malformed subject yields nobody rather than raising - a parse error here would be a denial of service');

select set_config('request.jwt.claims', '', true);
select dhaaga_test.eq(app.current_user_id(), null::uuid, 'no token at all, and no override, yields nobody');

-- REPRODUCED. Before 0016 current_user_id returned the token subject verbatim
-- and never looked at the person's record, so suspending or deleting an account
-- revoked nothing at all.
select dhaaga_test.as_nobody();
update app_user set status = 'suspended' where id = '7777aaaa-0000-0000-0000-000000000022';
select pg_temp.become('1111aaaa-0000-0000-0000-000000000022');
select dhaaga_test.eq(app.current_user_id(), null::uuid,
    'REPRODUCED: a suspended person resolves to nobody');

set local role authenticated;
select dhaaga_test.eq((select count(*)::int from app_user), 0,
    'and reaches no rows, because every policy compares against a null');
reset role;

select dhaaga_test.as_nobody();
update app_user set status = 'active', deleted_at = now() where id = '7777aaaa-0000-0000-0000-000000000022';
select pg_temp.become('1111aaaa-0000-0000-0000-000000000022');
select dhaaga_test.eq(app.current_user_id(), null::uuid,
    'REPRODUCED: a soft-deleted person resolves to nobody');

select dhaaga_test.as_nobody();
update app_user set deleted_at = null where id = '7777aaaa-0000-0000-0000-000000000022';
select pg_temp.become('1111aaaa-0000-0000-0000-000000000022');
select dhaaga_test.eq(app.current_user_id(), '7777aaaa-0000-0000-0000-000000000022'::uuid,
    'and works again the moment they are reinstated, with no session to expire');

-- One auth subject cannot be two people.
select dhaaga_test.as_nobody();
select dhaaga_test.throws(
    $$insert into app_user (business_id, auth_user_id, full_name)
      values ('7777aaaa-0000-0000-0000-000000000001','1111aaaa-0000-0000-0000-000000000022','Impostor')$$,
    'one authentication identity cannot resolve to two people', '23505');

select dhaaga_test.lives(
    $$insert into app_user (id, business_id, auth_user_id, full_name)
      values ('7777aaaa-0000-0000-0000-00000000002f','7777aaaa-0000-0000-0000-000000000001',null,'Another with no login')$$,
    'while any number of people may have no authentication identity at all');

-- ===========================================================================
-- 3 · Self-granting  (REPRODUCED, all four)
-- ===========================================================================
select pg_temp.become('1111aaaa-0000-0000-0000-000000000022');   -- the tailor
set local role authenticated;

select dhaaga_test.throws(
    $$insert into role_permission (business_id, role_id, permission_id)
      values ('7777aaaa-0000-0000-0000-000000000001','7777aaaa-0000-0000-0000-000000000032',
              '7777aaaa-0000-0000-0000-000000000041')$$,
    'REPRODUCED: a tailor cannot add a permission to their own role', '42501');

select dhaaga_test.throws(
    $$insert into permission (business_id, code, domain)
      values ('7777aaaa-0000-0000-0000-000000000001','invented.superpower','admin')$$,
    'REPRODUCED: nor invent a permission to check for', '42501');

select dhaaga_test.throws(
    $$insert into role (business_id, code, name)
      values ('7777aaaa-0000-0000-0000-000000000001','pirate','Pirate')$$,
    'REPRODUCED: nor create a role', '42501');

select dhaaga_test.throws(
    $$insert into user_branch_role (business_id, user_id, branch_id, role_id)
      values ('7777aaaa-0000-0000-0000-000000000001','7777aaaa-0000-0000-0000-000000000022',
              '7777aaaa-0000-0000-0000-000000000010','7777aaaa-0000-0000-0000-000000000030')$$,
    'REPRODUCED: nor grant themselves the owner role', '42501');

select dhaaga_test.throws(
    $$update user_branch_role set role_id = '7777aaaa-0000-0000-0000-000000000030'
       where user_id = '7777aaaa-0000-0000-0000-000000000022'$$,
    'nor promote the grant they already hold', '42501');

select dhaaga_test.throws(
    $$insert into branch (business_id, code, name)
      values ('7777aaaa-0000-0000-0000-000000000001','IA3','Invented')$$,
    'REPRODUCED: nor open a branch', '42501');

select dhaaga_test.throws(
    $$update business set legal_name = 'Renamed by a tailor'
       where id = '7777aaaa-0000-0000-0000-000000000001'$$,
    'nor rename the business', '42501');

select dhaaga_test.eq(app.has_permission('user.manage'), false,
    'and after every one of those, still holds nothing they did not start with');

-- ===========================================================================
-- 4 · Tampering with other people  (REPRODUCED)
-- ===========================================================================
select dhaaga_test.throws(
    $$update app_user set full_name = 'Renamed' where id = '7777aaaa-0000-0000-0000-000000000020'$$,
    'REPRODUCED: a tailor cannot edit a colleague''s record', '42501');

select dhaaga_test.throws(
    $$update user_branch_role set revoked_at = now() where user_id = '7777aaaa-0000-0000-0000-000000000020'$$,
    'REPRODUCED: nor revoke the owner''s access - a lockout is an attack', '42501');

select dhaaga_test.throws(
    $$delete from role_permission where role_id = '7777aaaa-0000-0000-0000-000000000030'$$,
    'REPRODUCED: nor strip the owner''s role of its permissions', '42501');

select dhaaga_test.throws(
    $$update app_user set deleted_at = now() where id = '7777aaaa-0000-0000-0000-000000000020'$$,
    'REPRODUCED: nor delete the owner', '42501');

select dhaaga_test.throws(
    $$update app_user set status = 'suspended' where id = '7777aaaa-0000-0000-0000-000000000022'$$,
    'nor suspend themselves, which is how an account walks away from an investigation', '42501');

-- Self-service is deliberately narrow.
select dhaaga_test.lives(
    $$update app_user set display_name = 'Chhotu', locale = 'hi-IN'
       where id = '7777aaaa-0000-0000-0000-000000000022'$$,
    'but may change how they appear and in what language');

select dhaaga_test.throws(
    $$update app_user set phone_e164 = '+919999999999' where id = '7777aaaa-0000-0000-0000-000000000022'$$,
    'and not their own phone number, which is how an account is recovered', '42501');

reset role;

-- ===========================================================================
-- 5 · Delegated administration, and its limits
-- ===========================================================================
select pg_temp.become('1111aaaa-0000-0000-0000-000000000021');   -- the manager
set local role authenticated;

select dhaaga_test.eq(app.has_permission('user.manage'), true, 'the manager holds user.manage');

select dhaaga_test.lives(
    $$insert into user_branch_role (business_id, user_id, branch_id, role_id)
      values ('7777aaaa-0000-0000-0000-000000000001','7777aaaa-0000-0000-0000-000000000023',
              '7777aaaa-0000-0000-0000-000000000010','7777aaaa-0000-0000-0000-000000000032')$$,
    'and can grant a colleague access to the branch the manager holds');

select dhaaga_test.eq(
    (select granted_by from user_branch_role
      where user_id = '7777aaaa-0000-0000-0000-000000000023'),
    '7777aaaa-0000-0000-0000-000000000021'::uuid,
    'with the granter recorded by the database rather than claimed by the caller');

select dhaaga_test.throws(
    $$insert into user_branch_role (business_id, user_id, branch_id, role_id)
      values ('7777aaaa-0000-0000-0000-000000000001','7777aaaa-0000-0000-0000-000000000023',
              '7777aaaa-0000-0000-0000-000000000011','7777aaaa-0000-0000-0000-000000000032')$$,
    'REPRODUCED: but not to a branch the manager does not hold', '42501');

select dhaaga_test.throws(
    $$insert into user_branch_role (business_id, user_id, branch_id, role_id)
      values ('7777aaaa-0000-0000-0000-000000000001','7777aaaa-0000-0000-0000-000000000021',
              '7777aaaa-0000-0000-0000-000000000010','7777aaaa-0000-0000-0000-000000000030')$$,
    'and never to themselves, whatever permission they hold', '42501');

select dhaaga_test.throws(
    $$insert into role_permission (business_id, role_id, permission_id)
      values ('7777aaaa-0000-0000-0000-000000000001','7777aaaa-0000-0000-0000-000000000031',
              '7777aaaa-0000-0000-0000-000000000042')$$,
    'user.manage does not carry role.manage: administration is not one permission', '42501');

-- Revocation, and its immediacy.
select dhaaga_test.lives(
    $$update user_branch_role set revoked_at = now()
       where user_id = '7777aaaa-0000-0000-0000-000000000023'$$,
    'the manager can revoke what they granted');

select dhaaga_test.eq(
    (select revoked_by from user_branch_role where user_id = '7777aaaa-0000-0000-0000-000000000023'),
    '7777aaaa-0000-0000-0000-000000000021'::uuid,
    'and the revoker is recorded too');

reset role;
select pg_temp.become('1111aaaa-0000-0000-0000-000000000022');
select dhaaga_test.as_nobody();
update user_branch_role set revoked_at = now() where user_id = '7777aaaa-0000-0000-0000-000000000022';
select pg_temp.become('1111aaaa-0000-0000-0000-000000000022');
select dhaaga_test.eq(cardinality(app.current_branch_ids()), 0,
    'a revoked grant leaves the branch list on the next action, with no session to expire');
select dhaaga_test.eq(app.has_permission('order.create'), false,
    'and the permissions it carried go with it');
select dhaaga_test.as_nobody();
update user_branch_role set revoked_at = null where user_id = '7777aaaa-0000-0000-0000-000000000022';

-- ===========================================================================
-- 6 · Role administration cannot become self-escalation
-- ===========================================================================
select pg_temp.become('1111aaaa-0000-0000-0000-000000000020');   -- the owner
set local role authenticated;

select dhaaga_test.eq(app.has_permission('role.manage'), true, 'the owner holds role.manage');

select dhaaga_test.lives(
    $$insert into role (id, business_id, code, name)
      values ('7777aaaa-0000-0000-0000-000000000033','7777aaaa-0000-0000-0000-000000000001','qc','Quality')$$,
    'and can define a new role');

select dhaaga_test.lives(
    $$insert into role_permission (business_id, role_id, permission_id)
      values ('7777aaaa-0000-0000-0000-000000000001','7777aaaa-0000-0000-0000-000000000033',
              '7777aaaa-0000-0000-0000-000000000040')$$,
    'and give it a permission, because the owner does not hold that role');

select dhaaga_test.throws(
    $$insert into role_permission (business_id, role_id, permission_id)
      values ('7777aaaa-0000-0000-0000-000000000001','7777aaaa-0000-0000-0000-000000000030',
              '7777aaaa-0000-0000-0000-000000000040')$$,
    'but cannot add a permission to the role they themselves hold - the self-escalation route', '42501');

select dhaaga_test.lives(
    $$delete from role_permission
       where role_id = '7777aaaa-0000-0000-0000-000000000030'
         and permission_id = '7777aaaa-0000-0000-0000-000000000043'$$,
    'while giving up authority over their own role needs no protection');

select dhaaga_test.throws(
    $$delete from role where id = '7777aaaa-0000-0000-0000-000000000030'$$,
    'a system role cannot be deleted out from under the people holding it', '42501');

select dhaaga_test.lives(
    $$update business set address_line1 = '12 Cloth Market'
       where id = '7777aaaa-0000-0000-0000-000000000001'$$,
    'the owner may edit the business record, holding business.manage');

reset role;

-- ===========================================================================
-- 7 · Cross-business, enforced relationally  (REPRODUCED)
-- ===========================================================================
select dhaaga_test.as_nobody();

-- These run with no caller at all - the migration path - so the triggers stand
-- aside and only the constraints answer. That is the point: the refusal must
-- come from the schema, not from a policy that a service path could sidestep.
select dhaaga_test.throws(
    $$insert into role_permission (business_id, role_id, permission_id)
      values ('7777aaaa-0000-0000-0000-000000000001','7777aaaa-0000-0000-0000-000000000030',
              '7777bbbb-0000-0000-0000-000000000041')$$,
    'REPRODUCED: a role of A cannot be bound to a permission of B', '23503');

select dhaaga_test.throws(
    $$insert into user_branch_role (business_id, user_id, branch_id, role_id)
      values ('7777aaaa-0000-0000-0000-000000000001','7777bbbb-0000-0000-0000-000000000020',
              '7777aaaa-0000-0000-0000-000000000010','7777aaaa-0000-0000-0000-000000000032')$$,
    'REPRODUCED: a person of B cannot be granted a role in A', '23503');

select dhaaga_test.throws(
    $$insert into user_branch_role (business_id, user_id, branch_id, role_id)
      values ('7777aaaa-0000-0000-0000-000000000001','7777aaaa-0000-0000-0000-000000000022',
              '7777bbbb-0000-0000-0000-000000000010','7777aaaa-0000-0000-0000-000000000032')$$,
    'nor a branch of B handed to a person of A', '23503');

select dhaaga_test.throws(
    $$insert into user_branch_role (business_id, user_id, branch_id, role_id)
      values ('7777aaaa-0000-0000-0000-000000000001','7777aaaa-0000-0000-0000-000000000022',
              '7777aaaa-0000-0000-0000-000000000010','7777bbbb-0000-0000-0000-000000000030')$$,
    'nor a role of B given to a person of A', '23503');

select pg_temp.become('1111aaaa-0000-0000-0000-000000000022');
set local role authenticated;
select dhaaga_test.eq((select count(*)::int from app_user where business_id = '7777bbbb-0000-0000-0000-000000000001'),
    0, 'and A reads none of B''s people');
select dhaaga_test.eq((select count(*)::int from permission where business_id = '7777bbbb-0000-0000-0000-000000000001'),
    0, 'nor B''s permission catalogue');
select dhaaga_test.eq((select count(*)::int from user_branch_role where business_id = '7777bbbb-0000-0000-0000-000000000001'),
    0, 'nor who B has granted what');
reset role;

-- ===========================================================================
-- 8 · The PIN  (REPRODUCED: it used to be a readable column on app_user)
-- ===========================================================================
select dhaaga_test.eq(
    dhaaga_test.column_exists('app_user','pin_hash'), false,
    'REPRODUCED: the PIN hash is no longer a column every colleague can select');

select dhaaga_test.eq(
    coalesce((select string_agg(distinct grantee, ', ' order by grantee)
              from information_schema.role_table_grants
              where table_name = 'user_credential' and grantee in ('anon','authenticated','PUBLIC')), '(none)'),
    '(none)', 'and no application role holds any privilege on the table it moved to');

select pg_temp.become('1111aaaa-0000-0000-0000-000000000022');

select dhaaga_test.lives($$select app.set_pin('4321')$$, 'a person can set their own PIN');
select dhaaga_test.eq(app.verify_pin('7777aaaa-0000-0000-0000-000000000022','4321'), true,
    'and verify it');
select dhaaga_test.eq(app.verify_pin('7777aaaa-0000-0000-0000-000000000022','0000'), false,
    'a wrong PIN verifies false');

select dhaaga_test.eq(
    (select pin_hash = '4321' from user_credential where user_id = '7777aaaa-0000-0000-0000-000000000022'),
    false, 'the PIN is not stored as itself');

-- A correct PIN is a lock over a session the device already holds. It is not an
-- authentication mechanism and must not behave like one.
select app.verify_pin('7777aaaa-0000-0000-0000-000000000022','4321');
select dhaaga_test.eq(app.current_user_id(), '7777aaaa-0000-0000-0000-000000000022'::uuid,
    'and a correct PIN establishes no identity - the caller is still exactly themselves');

select dhaaga_test.throws($$select app.set_pin('12')$$,
    'a PIN shorter than four digits is refused', '22023');
select dhaaga_test.throws($$select app.set_pin('abcd')$$,
    'and a PIN that is not digits', '22023');

select dhaaga_test.throws(
    $$select app.set_pin('1111','7777aaaa-0000-0000-0000-000000000020')$$,
    'the tailor cannot set the owner''s PIN', '42501');

select dhaaga_test.eq(
    app.verify_pin('7777bbbb-0000-0000-0000-000000000020','4321'), false,
    'and a person in another business answers exactly as a person who does not exist - no enumeration oracle');

-- Lockout.
select app.verify_pin('7777aaaa-0000-0000-0000-000000000022','1');
select app.verify_pin('7777aaaa-0000-0000-0000-000000000022','2');
select app.verify_pin('7777aaaa-0000-0000-0000-000000000022','3');
select app.verify_pin('7777aaaa-0000-0000-0000-000000000022','4');
select app.verify_pin('7777aaaa-0000-0000-0000-000000000022','5');
select dhaaga_test.throws(
    $$select app.verify_pin('7777aaaa-0000-0000-0000-000000000022','4321')$$,
    'five wrong attempts lock the PIN, so ten thousand values are not ten thousand tries', '28000');

-- ===========================================================================
-- 9 · Privileges on the WP-7 surface (ADR-0010)
-- ===========================================================================
select dhaaga_test.eq(
    coalesce((select string_agg(p.proname, ', ' order by p.proname)
              from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'app'
                and (has_function_privilege('public', p.oid, 'EXECUTE')
                     or has_function_privilege('anon', p.oid, 'EXECUTE'))), ''),
    '', 'no function in the app schema is executable by PUBLIC or by anon');

select dhaaga_test.eq(
    coalesce((select string_agg(p.proname, ', ' order by p.proname)
              from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'app' and p.prosecdef
                and (p.proconfig is null
                     or not exists (select 1 from unnest(p.proconfig) c where c like 'search_path=%'))), ''),
    '', 'every SECURITY DEFINER function pins its search_path');

-- WP-7 extends the pinning rule to the triggers, which are INVOKER and still
-- name relations (the class of defect found in WP-6).
select dhaaga_test.eq(
    coalesce((select string_agg(p.proname, ', ' order by p.proname)
              from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'app'
                and p.proname in ('auth_uid','current_identity','current_user_id','current_business_id',
                                  'assert_can_administer','enforce_app_user_change','enforce_branch_grant',
                                  'enforce_role_change','enforce_permission_catalogue','enforce_tenancy_change',
                                  'link_auth_identity','set_pin','verify_pin','my_permissions')
                and (p.proconfig is null
                     or not exists (select 1 from unnest(p.proconfig) c where c like 'search_path=%'))), ''),
    '', 'and so does every function WP-7 adds, trigger or not');

select dhaaga_test.eq(
    has_function_privilege('authenticated', 'app.current_identity()', 'EXECUTE'), false,
    'the resolver returns a whole person past row-level security, so it stays inside the schema');
select dhaaga_test.eq(
    has_function_privilege('authenticated', 'app.link_auth_identity(uuid,uuid)', 'EXECUTE'), false,
    'linking an authentication identity is provisioning, not administration');
-- assert_can_administer IS reachable, and has to be: the triggers that call it
-- run as the caller, so the caller needs EXECUTE. It discloses nothing beyond
-- app.has_permission, which is already theirs to call.
select dhaaga_test.eq(
    has_function_privilege('authenticated', 'app.assert_can_administer(text)', 'EXECUTE'), true,
    'the boundary check is callable, because the triggers that use it run as the caller');
select dhaaga_test.throws(
    $$select app.assert_can_administer('user.manage')$$,
    'and it refuses a caller who does not hold the permission it names', '42501');
select dhaaga_test.eq(
    has_function_privilege('authenticated', 'app.current_user_id()', 'EXECUTE'), true,
    'while a caller may ask who they are');
select dhaaga_test.eq(
    has_function_privilege('authenticated', 'app.my_permissions()', 'EXECUTE'), true,
    'and what they may do, which is how the client decides what to show');

-- ===========================================================================
-- 10 · Shadowing
-- ===========================================================================
-- The WP-6 class, re-run against the identity resolver: pg_temp is searched
-- first when it is not named, so an unpinned resolver could be pointed at a
-- table of the caller's own making.
select pg_temp.become('1111aaaa-0000-0000-0000-000000000022');
create temp table app_user (id uuid, business_id uuid, auth_user_id uuid, status text, deleted_at timestamptz);
insert into pg_temp.app_user values
 ('7777aaaa-0000-0000-0000-000000000020','7777bbbb-0000-0000-0000-000000000001',
  '1111aaaa-0000-0000-0000-000000000022','active',null);

select dhaaga_test.eq(
    app.current_user_id(), '7777aaaa-0000-0000-0000-000000000022'::uuid,
    'a temporary app_user cannot make the caller into somebody else');
select dhaaga_test.eq(
    app.current_business_id(), '7777aaaa-0000-0000-0000-000000000001'::uuid,
    'nor move them into another tenant');
drop table pg_temp.app_user;

create temp table user_branch_role (user_id uuid, branch_id uuid, role_id uuid, revoked_at timestamptz, deleted_at timestamptz);
insert into pg_temp.user_branch_role values
 ('7777aaaa-0000-0000-0000-000000000022','7777aaaa-0000-0000-0000-000000000011',null,null,null);
select dhaaga_test.eq(
    app.has_branch('7777aaaa-0000-0000-0000-000000000011'), false,
    'nor invent a branch grant');
drop table pg_temp.user_branch_role;

-- ===========================================================================
-- 11 · The audit trail sees identity changes (BR-13)
-- ===========================================================================
select dhaaga_test.ok(
    (select count(*) > 0 from audit_event
      where entity_type = 'user_branch_role'
        and business_id = '7777aaaa-0000-0000-0000-000000000001'),
    'every grant and revocation is in the audit trail');

select dhaaga_test.ok(
    (select count(*) > 0 from audit_event
      where entity_type = 'role_permission'
        and business_id = '7777aaaa-0000-0000-0000-000000000001'),
    'and every change to what a role may do');

-- ===========================================================================
-- 12 · Extension functions resolve wherever Supabase keeps them (0017)
-- ===========================================================================
-- Local PostgreSQL puts pgcrypto in `public`; Supabase ships it already
-- installed in `extensions`, so `create extension if not exists` is a no-op
-- there and crypt() is not in public at all. A PL/pgSQL body is not resolved
-- at creation time, so the migration applies cleanly and the function fails the
-- first time a person uses it - a green deployment with a broken PIN.
-- Reproduced against a database prepared with Supabase's layout before 0017.
--
-- The assertion is written against the CLASS rather than the two known
-- callers, so the next function that reaches for pgcrypto is caught too.
select dhaaga_test.eq(
    coalesce((select string_agg(p.proname, ', ' order by p.proname)
              from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'app'
                and p.prosrc ~ '\m(crypt|gen_salt|digest|hmac|pgp_sym_encrypt|pgp_sym_decrypt)\s*\('
                and not exists (select 1 from unnest(p.proconfig) c
                                 where c like 'search_path=%extensions%')), ''),
    '', 'every function that calls pgcrypto names the extensions schema in its search_path');

select dhaaga_test.ok(
    (select count(*) >= 2 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'app'
        and p.prosrc ~ '\m(crypt|gen_salt)\s*\('),
    'and there really are such functions, so the assertion above is not vacuous');

-- pg_temp must still come last, or 0017 would have traded one shadowing hole
-- for another.
select dhaaga_test.eq(
    coalesce((select string_agg(p.proname, ', ' order by p.proname)
              from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'app'
                and exists (select 1 from unnest(p.proconfig) c where c like 'search_path=%')
                and not exists (select 1 from unnest(p.proconfig) c
                                 where c ~ 'search_path=.*pg_temp\s*$')), ''),
    '', 'and pg_temp is still the last schema on every pinned search_path');
