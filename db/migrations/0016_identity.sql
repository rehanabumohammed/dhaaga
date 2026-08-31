-- 0016 · Identity, roles and permissions (WP-7)
--
-- WP-3 protected the tenant boundary. WP-7 protects the boundary INSIDE the
-- tenant, which until now did not exist: every authenticated user could write
-- to the tables that decide what they are allowed to do. Eighteen attacks were
-- reproduced against the running database before this migration was written;
-- ADR-0012 records each one with its reproduction.
--
-- The single sentence that explains most of what follows: authorization state
-- is not ordinary business data. A customer row is written by the person who
-- takes the order. A role_permission row decides who may take orders at all,
-- and must be written under a different set of rules.
--
-- Four separations, kept deliberately distinct (they were previously fused):
--
--   authentication   who proved they are a person   Supabase Auth, auth_user_id
--   application user which person that is           app_user.id
--   tenancy          which business they belong to  app_user.business_id
--   authorization    what they may do               user_branch_role -> role
--                                                   -> role_permission
--
-- Enforcement lives on the tables, not in setter functions (AP-5, and the WP-6
-- precedent): a check inside one function is a check the second caller skips.
-- Only two operations get functions instead, because neither can be expressed
-- as a row rule: hashing and verifying a PIN, and linking an authentication
-- identity, which is a provisioning act reserved to a trusted server path.

-- ===========================================================================
-- 1 · Authentication identity, separated from the application user
-- ===========================================================================
-- Until now app_user.id was documented as "matches the Supabase auth user id".
-- Nothing enforced it, the seed contradicted it, and it fused the authenticator
-- with the application's own key: a staff member who changes phone number gets
-- a new auth user, which under that model means rewriting every foreign key
-- that points at them. It also left no way to record someone who is paid and
-- assigned work but never logs in, which a tailoring shop is full of.
alter table app_user add column auth_user_id uuid;

comment on column app_user.auth_user_id is
    'The Supabase Auth user this person signs in as, or null for someone who is recorded and paid but never logs in. Set only through app.link_auth_identity by a trusted server path - never by a client, because it decides who a token becomes.';

-- No foreign key to auth.users: that schema exists on Supabase and not in the
-- local PostgreSQL the migrations are proven against, and a migration that
-- only applies in one of the two places is a migration that has not been
-- tested. The uniqueness below is the invariant that matters - one auth
-- identity cannot resolve to two people.
create unique index app_user_auth_identity_unique on app_user (auth_user_id)
    where auth_user_id is not null and deleted_at is null;

create index app_user_auth_lookup_idx on app_user (auth_user_id)
    where deleted_at is null;

comment on table app_user is
    'A person the business knows: staff, whether or not they log in. Authentication is a separate fact (auth_user_id); branch access is granted separately through user_branch_role.';

-- The PIN moves out. A hash sitting in a table every colleague can SELECT is a
-- hash every colleague can take away and attack offline, and a column-level
-- revoke would break `select *` for every ordinary read. Its own table, with no
-- grant to any application role, is the only shape that actually withholds it.
alter table app_user drop column pin_hash;
alter table app_user drop column pin_set_at;

create table user_credential (
    id                uuid primary key default gen_random_uuid(),
    business_id       uuid not null references business(id),

    user_id           uuid not null references app_user(id),
    -- bcrypt via pgcrypto. Never selected by any application role: the only
    -- reader is app.verify_pin, which runs as the owner and returns a boolean.
    pin_hash          text not null,
    pin_set_at        timestamptz not null default now(),
    -- A four-digit PIN has ten thousand values, so the lockout is not a nicety.
    failed_attempts   integer not null default 0,
    locked_until      timestamptz,

    created_at        timestamptz not null default now(),
    created_by        uuid,
    updated_at        timestamptz not null default now(),
    updated_by        uuid,
    deleted_at        timestamptz,
    row_version       integer not null default 1,

    constraint user_credential_one_per_user unique nulls not distinct (user_id, deleted_at)
);

comment on table user_credential is
    'The PIN that unlocks a cached session on a shared counter device. Not an authentication mechanism: a correct PIN establishes no identity in this database (ADR-0012).';
comment on column user_credential.pin_hash is
    'bcrypt hash. No application role holds SELECT on this table; app.verify_pin is the only reader.';

select app.attach_standard_triggers('user_credential');

-- Row-level security on a table nobody holds a grant on is not redundant: the
-- grant is one migration away from being added by mistake, and the coverage
-- assertion in db/tests/0010_isolation.sql requires every table to carry both.
-- The policy says what the privileges say - nobody - so the two cannot drift
-- into disagreeing.
alter table user_credential enable row level security;
create policy user_credential_no_application_access on user_credential
    for all to authenticated using (false) with check (false);

-- ===========================================================================
-- 2 · Cross-business integrity, enforced relationally
-- ===========================================================================
-- role_permission(role_id, permission_id) had two single-column foreign keys,
-- so nothing stopped a role of business A being bound to a permission of
-- business B. Reproduced. Composite keys make the tenant part of the
-- reference, so the database refuses it rather than a policy having to notice.
alter table app_user   add constraint app_user_business_key   unique (business_id, id);
alter table branch     add constraint branch_business_key     unique (business_id, id);
alter table role       add constraint role_business_key       unique (business_id, id);
alter table permission add constraint permission_business_key unique (business_id, id);

alter table role_permission
    add constraint role_permission_role_same_business
        foreign key (business_id, role_id) references role (business_id, id),
    add constraint role_permission_permission_same_business
        foreign key (business_id, permission_id) references permission (business_id, id);

alter table user_branch_role
    add constraint user_branch_role_user_same_business
        foreign key (business_id, user_id) references app_user (business_id, id),
    add constraint user_branch_role_branch_same_business
        foreign key (business_id, branch_id) references branch (business_id, id),
    add constraint user_branch_role_role_same_business
        foreign key (business_id, role_id) references role (business_id, id);

alter table user_credential
    add constraint user_credential_user_same_business
        foreign key (business_id, user_id) references app_user (business_id, id);

-- ===========================================================================
-- 3 · Identity resolution
-- ===========================================================================
-- One resolver, used by everything else. It is SECURITY DEFINER because it
-- reads app_user, and app_user's own policy calls it: without the owner's
-- rights this recurses. Pinned, because it names a relation.
create or replace function app.auth_uid()
returns uuid
language plpgsql
stable
set search_path = public, pg_temp
as $$
declare claim text;
begin
    claim := app.jwt() ->> 'sub';
    if claim is null or claim = '' then
        return null;
    end if;
    return claim::uuid;
exception when invalid_text_representation then
    return null;
end $$;

comment on function app.auth_uid() is
    'The verified Supabase Auth subject for this request, or null. This is an authentication fact and not an application user: use app.current_user_id() for that.';

create or replace function app.current_identity()
returns app_user
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
    v_auth  uuid;
    v_row   app_user;
    v_over  text;
begin
    -- A verified token always wins. The ordering is load-bearing: reversing it
    -- lets a caller reassign their own identity (ADR-0010, defect 1).
    v_auth := app.auth_uid();
    if v_auth is not null then
        select * into v_row from app_user u
         where u.auth_user_id = v_auth
           and u.deleted_at is null
           and u.status = 'active';
        return v_row;   -- null row when the subject maps to nobody usable
    end if;

    -- No token: a migration, a background job or a console session. The
    -- override names an APPLICATION user, not an auth subject, and is honoured
    -- only for a session that is trusted by virtue of who it logged in as.
    if app.session_is_trusted() then
        v_over := nullif(current_setting('app.actor_id', true), '');
        if v_over is not null then
            begin
                select * into v_row from app_user u
                 where u.id = v_over::uuid
                   and u.deleted_at is null
                   and u.status = 'active';
            exception when invalid_text_representation then
                return null;
            end;
            return v_row;
        end if;
    end if;

    return null;
end $$;

comment on function app.current_identity() is
    'The acting person as a row, or null. Resolves a verified auth subject to an active, undeleted app_user; falls back to the app.actor_id override only for a trusted session with no token. Suspension and soft deletion take effect here, which is what makes account revocation immediate.';

-- SECURITY DEFINER, like the resolver they wrap. Not for the read - the
-- resolver already runs as owner - but for the EXECUTE privilege:
-- app.current_identity() returns a whole app_user row past row-level security
-- and is therefore withheld from every application role, so an INVOKER wrapper
-- calling it is denied for exactly the callers that need it. Each returns one
-- scalar about the caller themselves, which is why the wrappers are safe to
-- expose when the resolver is not.
create or replace function app.current_user_id()
returns uuid
language sql
stable
security definer
set search_path = public, pg_temp
as $$
    select (app.current_identity()).id;
$$;

comment on function app.current_user_id() is
    'The acting application user. Null for an unauthenticated, unknown, suspended or deleted caller - and null reaches nothing, because every policy compares against it.';

create or replace function app.current_business_id()
returns uuid
language sql
stable
security definer
set search_path = public, pg_temp
as $$
    select (app.current_identity()).business_id;
$$;

comment on function app.current_business_id() is
    'The caller''s tenant, derived from their user record rather than trusted from a token claim: a claim can be forged, a row cannot.';

-- ===========================================================================
-- 4 · The authorization boundary
-- ===========================================================================
-- Every write to the tables that decide what a person may do passes through
-- here. On the tables rather than in setter functions, so a future domain
-- service, a bulk import or a console session with a user context is bound by
-- the same rules (AP-5).
--
-- The rules, in the order they are applied:
--   0. No user context - a migration, a seed, a restore. Recorded by the audit
--      trail with source 'system' or 'console', not silently permitted.
--   1. Nobody may change their own authorization. Not their grants, not the
--      permissions of a role they hold, not their own account status.
--   2. A grant may only be made into a branch the granter themselves holds.
--   3. The named administrative permission is required.
--   4. Authentication facts are not administrative: only a trusted session may
--      decide which auth subject a person signs in as.

create or replace function app.assert_can_administer(p_permission text)
returns void
language plpgsql
stable
set search_path = public, pg_temp
as $$
begin
    if not app.has_permission(p_permission) then
        raise exception 'refused: this action requires the % permission', p_permission
            using errcode = 'insufficient_privilege';
    end if;
end $$;

comment on function app.assert_can_administer(text) is
    'Refuses unless the caller holds a named administrative permission. Separate from app.has_permission so the refusal, and its SQLSTATE, are uniform.';

-- --- app_user ---------------------------------------------------------------
create or replace function app.enforce_app_user_change()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
    v_me uuid := app.current_user_id();
begin
    if v_me is null then
        return coalesce(new, old);
    end if;

    -- Who a person signs in as is an authentication fact. Granting it to an
    -- administrator would let one take over any account in the business by
    -- pointing it at their own auth subject; granting it to the user
    -- themselves would let them point their colleague's row at their own.
    if new.auth_user_id is distinct from old.auth_user_id and not app.session_is_trusted() then
        raise exception 'refused: an authentication identity is linked by a trusted server path, not by a client'
            using errcode = 'insufficient_privilege',
                  hint = 'use app.link_auth_identity from a service-role session';
    end if;

    if TG_OP = 'UPDATE' and old.id = v_me then
        -- Self-service is narrow on purpose: how you appear, and in what
        -- language. Everything else about you is an administrative fact.
        if new.business_id  is distinct from old.business_id
        or new.status       is distinct from old.status
        or new.deleted_at   is distinct from old.deleted_at
        or new.full_name    is distinct from old.full_name
        or new.employee_code is distinct from old.employee_code
        or new.phone_e164   is distinct from old.phone_e164
        or new.email        is distinct from old.email then
            raise exception 'refused: a person may not change their own record beyond display name and locale'
                using errcode = 'insufficient_privilege';
        end if;
        return new;
    end if;

    perform app.assert_can_administer('user.manage');

    -- An administrator may suspend or delete a colleague, but not themselves:
    -- self-suspension is how an account escapes an investigation.
    if TG_OP <> 'INSERT' and old.id = v_me
       and (new.status is distinct from old.status or new.deleted_at is distinct from old.deleted_at) then
        raise exception 'refused: a person may not change their own account status'
            using errcode = 'insufficient_privilege';
    end if;

    return coalesce(new, old);
end $$;

comment on function app.enforce_app_user_change() is
    'Who may create, alter, suspend or delete a person. Self-service is limited to display name and locale; linking an authentication identity is reserved to a trusted session.';

drop trigger if exists b_app_user_authz on app_user;
create trigger b_app_user_authz
    before insert or update or delete on app_user
    for each row execute function app.enforce_app_user_change();

-- --- user_branch_role: the grant itself --------------------------------------
create or replace function app.enforce_branch_grant()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
    v_me     uuid := app.current_user_id();
    v_target uuid := coalesce(new.user_id, old.user_id);
    v_branch uuid := coalesce(new.branch_id, old.branch_id);
begin
    if v_me is null then
        return coalesce(new, old);
    end if;

    -- The whole of WP-7 in one rule. A person may not widen, narrow, restore
    -- or retarget their own access: not by inserting a grant, not by editing
    -- one, not by clearing the revoked_at that took it away.
    if v_target = v_me or (TG_OP = 'UPDATE' and old.user_id = v_me) then
        raise exception 'refused: a person may not grant, alter or restore their own access'
            using errcode = 'insufficient_privilege',
                  hint = 'someone who holds user.manage for that branch must do it';
    end if;

    perform app.assert_can_administer('user.manage');

    -- Authority is per branch. A manager covering one outlet must not be able
    -- to hand out access to another, and must not be able to reach into a
    -- branch by editing a grant that already points somewhere else.
    if not app.has_branch(v_branch) then
        raise exception 'refused: this caller holds no grant for branch %, so may not grant it to others', v_branch
            using errcode = 'insufficient_privilege';
    end if;
    if TG_OP = 'UPDATE' and not app.has_branch(old.branch_id) then
        raise exception 'refused: this caller holds no grant for branch %', old.branch_id
            using errcode = 'insufficient_privilege';
    end if;

    -- Attribution is recorded by the database, not supplied by the caller.
    if TG_OP = 'INSERT' then
        new.granted_by := v_me;
    elsif TG_OP = 'UPDATE' and new.revoked_at is not null and old.revoked_at is null then
        new.revoked_by := v_me;
    end if;

    return coalesce(new, old);
end $$;

comment on function app.enforce_branch_grant() is
    'Who may grant and revoke branch access. Never yourself; only into a branch you hold; only with user.manage. Granter and revoker are recorded by the database rather than claimed by the caller.';

drop trigger if exists b_user_branch_role_authz on user_branch_role;
create trigger b_user_branch_role_authz
    before insert or update or delete on user_branch_role
    for each row execute function app.enforce_branch_grant();

-- --- role and permission ------------------------------------------------------
create or replace function app.enforce_role_change()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
    v_me   uuid := app.current_user_id();
    v_role uuid;
begin
    if v_me is null then
        return coalesce(new, old);
    end if;

    perform app.assert_can_administer('role.manage');

    if TG_TABLE_NAME = 'role_permission' then
        v_role := coalesce(new.role_id, old.role_id);

        -- Self-escalation, closed at its root. Adding a permission to a role
        -- you hold is granting yourself that permission with an extra step.
        -- Removals are allowed: giving up authority needs no protection.
        if TG_OP <> 'DELETE' and exists (
            select 1 from user_branch_role ubr
            where ubr.user_id = v_me and ubr.role_id = v_role
              and ubr.revoked_at is null and ubr.deleted_at is null)
        then
            raise exception 'refused: a permission may not be added to a role the caller holds'
                using errcode = 'insufficient_privilege',
                      hint = 'that would be granting yourself the permission by another route';
        end if;

    elsif TG_TABLE_NAME = 'role' and TG_OP = 'DELETE' and old.is_system then
        raise exception 'refused: a system role may not be deleted; its permissions are editable'
            using errcode = 'insufficient_privilege';
    end if;

    return coalesce(new, old);
end $$;

comment on function app.enforce_role_change() is
    'Who may define roles and what they contain. Requires role.manage, and refuses to add a permission to a role the caller holds - the self-escalation route that makes every other check pointless.';

drop trigger if exists b_role_authz on role;
create trigger b_role_authz
    before insert or update or delete on role
    for each row execute function app.enforce_role_change();

drop trigger if exists b_role_permission_authz on role_permission;
create trigger b_role_permission_authz
    before insert or update or delete on role_permission
    for each row execute function app.enforce_role_change();

-- The permission catalogue is the vocabulary the whole model is written in.
-- A caller who can add to it can name anything they like and then check for it.
create or replace function app.enforce_permission_catalogue()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
    if app.current_user_id() is null then
        return coalesce(new, old);
    end if;
    raise exception 'refused: the permission catalogue is defined by the product, not by a tenant'
        using errcode = 'insufficient_privilege',
              hint = 'permissions arrive with a migration or a seed; roles are what a business composes';
end $$;

comment on function app.enforce_permission_catalogue() is
    'The set of permissions that exist is product vocabulary. A business composes roles out of it and does not extend it.';

drop trigger if exists b_permission_authz on permission;
create trigger b_permission_authz
    before insert or update or delete on permission
    for each row execute function app.enforce_permission_catalogue();

-- --- business and branch: tenancy structure ----------------------------------
create or replace function app.enforce_tenancy_change()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
    if app.current_user_id() is null then
        return coalesce(new, old);
    end if;

    if TG_TABLE_NAME = 'business' then
        if TG_OP <> 'UPDATE' then
            raise exception 'refused: a business is created and closed by the product, not from inside itself'
                using errcode = 'insufficient_privilege';
        end if;
        perform app.assert_can_administer('business.manage');
    else
        perform app.assert_can_administer('branch.manage');
    end if;

    return coalesce(new, old);
end $$;

comment on function app.enforce_tenancy_change() is
    'Editing the business record needs business.manage; opening or editing a branch needs branch.manage. Neither is something an ordinary user does in passing - a branch nobody granted is still a branch with its own GSTIN and numbering.';

drop trigger if exists b_business_authz on business;
create trigger b_business_authz
    before insert or update or delete on business
    for each row execute function app.enforce_tenancy_change();

drop trigger if exists b_branch_authz on branch;
create trigger b_branch_authz
    before insert or update or delete on branch
    for each row execute function app.enforce_tenancy_change();

-- ===========================================================================
-- 5 · Provisioning: the one trusted-only operation
-- ===========================================================================
-- Linking an auth subject to a person is what turns a row into someone who can
-- log in. Everything else in this migration can be delegated to a user holding
-- an administrative permission; this cannot, because it is the step that would
-- let an administrator become a colleague.
create or replace function app.link_auth_identity(
    p_user_id uuid,
    p_auth_uid uuid
) returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
    if not app.session_is_trusted() then
        raise exception 'refused: linking an authentication identity requires a trusted server session'
            using errcode = 'insufficient_privilege';
    end if;

    update app_user set auth_user_id = p_auth_uid
     where id = p_user_id and deleted_at is null;

    if not found then
        raise exception 'no such person: %', p_user_id using errcode = 'no_data_found';
    end if;
end $$;

comment on function app.link_auth_identity(uuid, uuid) is
    'Points a person at the Supabase Auth subject they sign in as. Trusted sessions only: this is the step that decides who a token becomes.';

-- ===========================================================================
-- 6 · The PIN
-- ===========================================================================
-- What this is: a lock over a session the device already holds, so a counter
-- assistant can hand the tablet to a colleague without handing over their own
-- logged-in app. What it is NOT: an authentication mechanism. A correct PIN
-- establishes no identity in this database, which is why verify_pin returns a
-- boolean and nothing else. Duplicating Supabase Auth here would mean minting
-- credentials, and that is a thing this system deliberately does not do.
create or replace function app.set_pin(p_pin text, p_user_id uuid default null)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_me     uuid := app.current_user_id();
    v_target uuid := coalesce(p_user_id, v_me);
    v_user   app_user;
begin
    select * into v_user from app_user u
     where u.id = v_target and u.deleted_at is null;
    if not found then
        raise exception 'no such person: %' , v_target using errcode = 'no_data_found';
    end if;

    perform app.assert_tenant_write(v_user.business_id, null);

    -- Setting someone else's PIN is an administrative act; setting your own is
    -- not. Both are refused to a caller with no identity and no trust.
    if v_me is not null and v_target <> v_me then
        perform app.assert_can_administer('user.manage');
    elsif v_me is null and not app.session_is_trusted() then
        raise exception 'refused: no caller' using errcode = 'insufficient_privilege';
    end if;

    if p_pin !~ '^[0-9]{4,8}$' then
        raise exception 'a PIN is four to eight digits'
            using errcode = 'invalid_parameter_value';
    end if;

    insert into user_credential (business_id, user_id, pin_hash, pin_set_at, failed_attempts, locked_until)
    values (v_user.business_id, v_target, crypt(p_pin, gen_salt('bf')), now(), 0, null)
    on conflict (user_id, deleted_at) do update
        set pin_hash = excluded.pin_hash,
            pin_set_at = now(),
            failed_attempts = 0,
            locked_until = null;
end $$;

comment on function app.set_pin(text, uuid) is
    'Sets a person''s device PIN. Your own needs nothing; somebody else''s needs user.manage. The hash never leaves this function''s table.';

create or replace function app.verify_pin(p_user_id uuid, p_pin text)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_user app_user;
    v_cred user_credential;
    v_ok   boolean;
begin
    select * into v_user from app_user u
     where u.id = p_user_id and u.deleted_at is null and u.status = 'active';
    if not found then
        return false;                      -- says nothing about who exists
    end if;

    -- A person in another business is answered exactly as a person who does
    -- not exist. Raising here instead would turn this function into an
    -- enumeration oracle: refusal would mean "real and active elsewhere",
    -- false would mean "no such id", and the difference is the leak.
    if app.current_user_id() is not null
       and v_user.business_id is distinct from app.current_business_id() then
        return false;
    end if;

    select * into v_cred from user_credential c
     where c.user_id = p_user_id and c.deleted_at is null;
    if not found then
        return false;
    end if;

    if v_cred.locked_until is not null and v_cred.locked_until > now() then
        raise exception 'too many attempts; try again after %', v_cred.locked_until
            using errcode = 'invalid_authorization_specification';
    end if;

    v_ok := (v_cred.pin_hash = crypt(p_pin, v_cred.pin_hash));

    if v_ok then
        update user_credential set failed_attempts = 0, locked_until = null where id = v_cred.id;
    else
        update user_credential
           set failed_attempts = failed_attempts + 1,
               locked_until = case when failed_attempts + 1 >= 5
                                   then now() + interval '15 minutes' else null end
         where id = v_cred.id;
    end if;

    return v_ok;
end $$;

comment on function app.verify_pin(uuid, text) is
    'Whether a PIN matches, with a lockout after five failures. Authorises nothing: the caller still needs that person''s own token to act as them (ADR-0012).';

-- ===========================================================================
-- 7 · Reading the model
-- ===========================================================================
-- The client needs to know what the current user may do, in order to show or
-- hide things. It must get that from the database rather than deciding for
-- itself, and it must be a view of the CALLER's own permissions only.
create or replace function app.my_permissions()
returns setof text
language sql
stable
security definer
set search_path = public, pg_temp
as $$
    select distinct p.code
      from user_branch_role ubr
      join role_permission rp on rp.role_id = ubr.role_id and rp.deleted_at is null
      join permission p on p.id = rp.permission_id and p.deleted_at is null
     where ubr.user_id = app.current_user_id()
       and ubr.revoked_at is null
       and ubr.deleted_at is null
     order by 1;
$$;

comment on function app.my_permissions() is
    'Every permission the caller currently holds. Their own only - it takes no parameter, so there is nothing to point at somebody else.';

-- ===========================================================================
-- 8 · Privileges — deliberate, never default (ADR-0010)
-- ===========================================================================
-- The credential table is reachable by nobody. Not a narrower grant: none.
revoke all on table user_credential from public, anon, authenticated;
grant all on table user_credential to service_role;

revoke all on function app.auth_uid() from public, anon, authenticated;
revoke all on function app.current_identity() from public, anon, authenticated;
revoke all on function app.assert_can_administer(text) from public, anon, authenticated;
revoke all on function app.enforce_app_user_change() from public, anon, authenticated;
revoke all on function app.enforce_branch_grant() from public, anon, authenticated;
revoke all on function app.enforce_role_change() from public, anon, authenticated;
revoke all on function app.enforce_permission_catalogue() from public, anon, authenticated;
revoke all on function app.enforce_tenancy_change() from public, anon, authenticated;
revoke all on function app.link_auth_identity(uuid, uuid) from public, anon, authenticated;
revoke all on function app.set_pin(text, uuid) from public, anon, authenticated;
revoke all on function app.verify_pin(uuid, text) from public, anon, authenticated;
revoke all on function app.my_permissions() from public, anon, authenticated;

-- current_user_id and current_business_id are replaced above, which resets
-- nothing about their ACL - but stating it is cheaper than assuming it.
revoke all on function app.current_user_id() from public, anon;
revoke all on function app.current_business_id() from public, anon;

grant execute on function app.auth_uid()                    to authenticated, service_role;
grant execute on function app.current_user_id()             to authenticated, service_role;
grant execute on function app.current_business_id()         to authenticated, service_role;
grant execute on function app.my_permissions()              to authenticated, service_role;
grant execute on function app.set_pin(text, uuid)           to authenticated, service_role;
grant execute on function app.verify_pin(uuid, text)        to authenticated, service_role;

-- The triggers above are SECURITY INVOKER - they must be, or they would read
-- past the row-level security they are meant to work alongside - so the caller
-- whose write they are checking needs EXECUTE on the helper they call. That is
-- safe here: assert_can_administer raises or returns void based on the
-- caller's OWN permissions, and tells them nothing app.has_permission does not
-- already tell them.
grant execute on function app.assert_can_administer(text)   to authenticated, service_role;

-- current_identity returns a whole app_user row past row-level security, so it
-- stays inside the schema; link_auth_identity is provisioning.
grant execute on function app.current_identity()            to service_role;
grant execute on function app.link_auth_identity(uuid,uuid) to service_role;
