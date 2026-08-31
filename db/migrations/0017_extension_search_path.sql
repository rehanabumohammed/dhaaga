-- 0017 · Reaching pgcrypto wherever Supabase keeps it (WP-7 cloud pre-flight)
--
-- Found by the pre-flight review before the first cloud push, and reproduced.
--
-- Local PostgreSQL and Supabase Cloud do not put pgcrypto in the same place.
-- Locally `create extension if not exists pgcrypto` installs it into `public`,
-- because that is the first writable schema on the default search_path. On
-- Supabase pgcrypto is ALREADY installed, into a schema called `extensions`,
-- so the same statement is a no-op and crypt() and gen_salt() are not in public
-- at all.
--
-- Migration 0016 pinned `search_path = public, pg_temp` on app.set_pin and
-- app.verify_pin - correctly, against the pg_temp shadowing class from WP-6 -
-- and then called crypt() and gen_salt() unqualified. Under Supabase's layout
-- those do not resolve.
--
-- The failure mode is the dangerous one. A PL/pgSQL body is not resolved when
-- the function is created, so the migration applies cleanly and `supabase db
-- push` reports success. Reproduced against a local database prepared with
-- Supabase's layout:
--
--     up: applied 16 migration(s)          <- deployment "succeeded"
--     select app.set_pin('4321', ...);
--     ERROR:  function gen_salt(unknown) does not exist
--
-- A green deployment with a broken PIN, discovered by the first person to set
-- one. This is exactly the local/cloud divergence ADR-0001 exists to prevent,
-- and it got through because every earlier migration used only
-- gen_random_uuid(), which has been in the PostgreSQL core since 13 and is
-- therefore never affected by where pgcrypto lives. WP-7 is the first code to
-- need pgcrypto itself.
--
-- The fix is to name both possible homes. A schema listed in search_path that
-- does not exist is ignored, so one definition is correct in both environments
-- and neither has to be special-cased. `extensions` is owned by supabase_admin
-- and application roles hold USAGE but not CREATE on it, so naming it opens no
-- shadowing route; pg_temp stays last, which is the property that matters.
--
-- 0016 is already committed and delivered, and applied migrations are immutable
-- (ADR-0002), so this arrives as its own migration rather than an edit.

create or replace function app.set_pin(p_pin text, p_user_id uuid default null)
returns void
language plpgsql
security definer
set search_path = public, extensions, pg_temp
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
    'Sets a person''s device PIN. Your own needs nothing; somebody else''s needs user.manage. The hash never leaves this function''s table. search_path names `extensions` because that is where Supabase keeps pgcrypto (0017).';

create or replace function app.verify_pin(p_user_id uuid, p_pin text)
returns boolean
language plpgsql
security definer
set search_path = public, extensions, pg_temp
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
    'Whether a PIN matches, with a lockout after five failures. Authorises nothing: the caller still needs that person''s own token to act as them (ADR-0012). search_path names `extensions` because that is where Supabase keeps pgcrypto (0017).';

-- create or replace preserves the ACL, but stating it costs one line and
-- removes the need for a reader to know that (ADR-0010).
revoke all on function app.set_pin(text, uuid) from public, anon, authenticated;
revoke all on function app.verify_pin(uuid, text) from public, anon, authenticated;
grant execute on function app.set_pin(text, uuid)    to authenticated, service_role;
grant execute on function app.verify_pin(uuid, text) to authenticated, service_role;
