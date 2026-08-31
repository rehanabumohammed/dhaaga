-- Rollback of 0016 · Identity, roles and permissions (WP-7)
--
-- Restores app_user to its 0003 shape, including the pin columns, so a rebuild
-- from empty and a teardown produce the same schema either way.

drop trigger if exists b_branch_authz on branch;
drop trigger if exists b_business_authz on business;
drop trigger if exists b_permission_authz on permission;
drop trigger if exists b_role_permission_authz on role_permission;
drop trigger if exists b_role_authz on role;
drop trigger if exists b_user_branch_role_authz on user_branch_role;
drop trigger if exists b_app_user_authz on app_user;

drop function if exists app.my_permissions();
drop function if exists app.verify_pin(uuid, text);
drop function if exists app.set_pin(text, uuid);
drop function if exists app.link_auth_identity(uuid, uuid);
drop function if exists app.enforce_tenancy_change();
drop function if exists app.enforce_permission_catalogue();
drop function if exists app.enforce_role_change();
drop function if exists app.enforce_branch_grant();
drop function if exists app.enforce_app_user_change();
drop function if exists app.assert_can_administer(text);

alter table user_credential drop constraint if exists user_credential_user_same_business;
drop table if exists user_credential;

alter table user_branch_role
    drop constraint if exists user_branch_role_role_same_business,
    drop constraint if exists user_branch_role_branch_same_business,
    drop constraint if exists user_branch_role_user_same_business;

alter table role_permission
    drop constraint if exists role_permission_permission_same_business,
    drop constraint if exists role_permission_role_same_business;

alter table permission drop constraint if exists permission_business_key;
alter table role       drop constraint if exists role_business_key;
alter table branch     drop constraint if exists branch_business_key;
alter table app_user   drop constraint if exists app_user_business_key;

-- Restore the identity resolution of 0014 exactly.
create or replace function app.current_business_id()
returns uuid
language sql
stable
security definer
set search_path = public, pg_temp
as $$
    select u.business_id
    from app_user u
    where u.id = app.current_user_id()
      and u.deleted_at is null
    limit 1;
$$;

create or replace function app.current_user_id()
returns uuid
language plpgsql
stable
as $$
declare
    claim    text;
    override text;
begin
    claim := app.jwt() ->> 'sub';
    if claim is not null and claim <> '' then
        return claim::uuid;
    end if;

    if app.session_is_trusted() then
        override := nullif(current_setting('app.actor_id', true), '');
        if override is not null then
            return override::uuid;
        end if;
    end if;

    return null;
exception when invalid_text_representation then
    return null;
end $$;

grant execute on function app.current_user_id() to authenticated, service_role;
grant execute on function app.current_business_id() to authenticated, service_role;

drop function if exists app.current_identity();
drop function if exists app.auth_uid();

drop index if exists app_user_auth_lookup_idx;
drop index if exists app_user_auth_identity_unique;
alter table app_user drop column if exists auth_user_id;

alter table app_user add column pin_hash text;
alter table app_user add column pin_set_at timestamptz;

comment on table app_user is 'A person who logs in. id matches the Supabase auth user id. Branch access is granted separately via user_branch_role.';
comment on column app_user.pin_hash is 'PIN for fast switching on a shared device. Written by a security-definer function; never selected by a client.';
