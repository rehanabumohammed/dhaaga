-- 0014 · The server-side identity override requires a trusted session
--
-- Found by the WP-5 security regression gate, completing the fix begun in 0013.
--
-- 0013 made a verified token authoritative: with a token present, app.actor_id
-- is ignored. That closed the reported bypass. It left one residual path:
--
--     set_config('request.jwt.claims', '', true);   -- drop my own token
--     set_config('app.actor_id', '<any user>', true);
--     -- now I am that user
--
-- pg_catalog.set_config is executable by PUBLIC, so any caller able to run
-- arbitrary SQL can do this. A PostgREST client cannot - it reaches only table
-- CRUD and exposed RPC, and set_config is neither - so this was not reachable
-- by the application. But "not reachable through the front door we happen to
-- ship" is a weaker property than "not reachable", and identity is the wrong
-- place to accept the weaker one.
--
-- The override now additionally requires a trusted session. Trust is decided by
-- session_user, which is immune to both SET ROLE and SECURITY DEFINER nesting -
-- unlike current_user, which becomes the function owner inside a definer
-- function and would therefore report "trusted" for every caller.

create or replace function app.session_is_trusted()
returns boolean
language sql
stable
as $$
    -- A session is trusted when it logged in as the role that owns the schema,
    -- or as a member of it: migrations, scheduled jobs, a console session.
    -- PostgREST logs in as `authenticator` and switches role per request; that
    -- role is not a member of the owner, so every API request is untrusted here
    -- regardless of which role it switches to.
    --
    -- Derived from the schema's actual owner rather than a hard-coded name, so
    -- this keeps working if ownership ever changes.
    select pg_has_role(
        session_user,
        (select nspowner from pg_namespace where nspname = 'app'),
        'MEMBER');
$$;

comment on function app.session_is_trusted() is
    'True for a direct database login by the schema owner - a migration, a job, a console. False for every PostgREST request. Uses session_user because it survives SET ROLE and SECURITY DEFINER, which current_user does not.';

create or replace function app.current_user_id()
returns uuid
language plpgsql
stable
as $$
declare
    claim    text;
    override text;
begin
    -- A verified token is the identity. Nothing a caller can set displaces it.
    claim := app.jwt() ->> 'sub';
    if claim is not null and claim <> '' then
        return claim::uuid;
    end if;

    -- No token. The server-side override applies only in a trusted session, so
    -- an API caller cannot reach it by discarding its own token first.
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

comment on function app.current_user_id() is
    'The acting user. A verified JWT subject always wins; the app.actor_id override applies only in a trusted session with no token. Both conditions are load-bearing: dropping either restores an impersonation path.';

-- ===========================================================================
-- Functions must fail closed too
-- ===========================================================================
-- Caught by the security assertions while writing this migration: PostgreSQL
-- grants EXECUTE on a NEW function to PUBLIC. Migration 0010 closed that for
-- future tables and did not close it for future functions, so every migration
-- that adds one silently re-opened the hole 0013 had just shut.
--
-- The obvious fix does not work, and it is worth recording why rather than
-- leaving a line that looks like protection.
--
--     alter default privileges in schema app revoke execute on functions from public;
--
-- is a silent no-op. ALTER DEFAULT PRIVILEGES can only remove privileges that a
-- previous default GRANT added; it cannot revoke PostgreSQL's built-in default.
-- Verified empirically: after running it, pg_default_acl holds no row, a newly
-- created function has a NULL proacl - which means "built-in default applies" -
-- and PUBLIC can execute it. Adding a positive grant first does not help; the
-- stored ACL still contains the PUBLIC entry (=X/owner).
--
-- So there is no database-level default that makes new functions fail closed.
-- The control is therefore the test suite: db/tests/0014_security_audit.sql
-- asserts that NO function in this schema is executable by PUBLIC or anon, and
-- fails the build by name if one is. That assertion is what caught this
-- migration granting PUBLIC execute on its own new functions, and it is what
-- will catch the next one. Every migration that creates a function must revoke
-- explicitly, as below.
revoke all on function app.session_is_trusted() from public, anon, authenticated;
revoke all on function app.current_user_id()    from public, anon, authenticated;

grant execute on function app.session_is_trusted() to authenticated, service_role;
grant execute on function app.current_user_id()    to authenticated, service_role;
