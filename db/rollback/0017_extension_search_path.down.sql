-- Rollback of 0017 · restores the 0016 definitions, which name only `public`.
--
-- Rolling this back re-introduces the Supabase incompatibility on purpose: a
-- rollback must return the schema to the state 0016 left it in, not to a state
-- that never existed.

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
        return false;
    end if;

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

revoke all on function app.set_pin(text, uuid) from public, anon, authenticated;
revoke all on function app.verify_pin(uuid, text) from public, anon, authenticated;
grant execute on function app.set_pin(text, uuid)    to authenticated, service_role;
grant execute on function app.verify_pin(uuid, text) to authenticated, service_role;
