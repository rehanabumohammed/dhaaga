-- 0009 · Row-level security, roles and the tenant predicate
--
-- WP-3. Isolation stops being a property of the application and becomes a
-- property of the database (AP-5). After this migration a bug in a query, a
-- misconfigured client, or a direct call with a publishable key cannot reach
-- another branch's or another business's rows.
--
-- Why this matters concretely: Supabase exposes every table in `public` through
-- PostgREST, reached with a key that ships inside the app. Without policies,
-- that key is unrestricted access. With them, it can only ever see what the
-- signed-in user is entitled to.
--
-- Two shapes of policy, applied uniformly:
--   business-scoped  business_id = the caller's business
--   branch-scoped    ... and branch_id is one the caller is granted, or null
--
-- Permission-level enforcement (who may discount, who may reverse a payment)
-- is WP-7. This migration is about which ROWS exist for a caller at all.

-- ===========================================================================
-- Roles — parity with Supabase
-- ===========================================================================
-- Supabase provides these; a local database does not. Creating them here means
-- the isolation suite exercises the same roles locally, in CI and in production
-- rather than testing a fiction.
do $$
begin
    if not exists (select 1 from pg_roles where rolname = 'anon') then
        create role anon nologin noinherit;
    end if;
    if not exists (select 1 from pg_roles where rolname = 'authenticated') then
        create role authenticated nologin noinherit;
    end if;
    if not exists (select 1 from pg_roles where rolname = 'service_role') then
        create role service_role nologin noinherit bypassrls;
    end if;
end $$;

grant usage on schema public to anon, authenticated, service_role;
grant usage on schema app to authenticated, service_role;

-- ===========================================================================
-- Session context helpers
-- ===========================================================================
-- These are SECURITY DEFINER because they must read app_user and
-- user_branch_role to answer "who is this and what may they reach" -- and those
-- tables are themselves protected by policies that depend on the answer. A
-- plain function would recurse. search_path is pinned so a caller cannot
-- shadow a table and change what the function sees.

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

comment on function app.current_business_id() is
    'The caller''s tenant, derived from their user record rather than trusted from a token claim: a claim can be forged, a row cannot.';

create or replace function app.current_branch_ids()
returns uuid[]
language sql
stable
security definer
set search_path = public, pg_temp
as $$
    select coalesce(array_agg(distinct ubr.branch_id), array[]::uuid[])
    from user_branch_role ubr
    where ubr.user_id = app.current_user_id()
      and ubr.revoked_at is null
      and ubr.deleted_at is null;
$$;

comment on function app.current_branch_ids() is
    'Branches the caller currently holds a grant for. A revoked grant disappears from this list immediately, which is what makes revocation take effect on the next action.';

create or replace function app.has_branch(target uuid)
returns boolean
language sql
stable
as $$
    -- A null branch means the row belongs to the business rather than to an
    -- outlet; anyone in the business may reach it.
    select target is null or target = any(app.current_branch_ids());
$$;

grant execute on function app.current_user_id() to authenticated, service_role;
grant execute on function app.current_business_id() to authenticated, service_role;
grant execute on function app.current_branch_ids() to authenticated, service_role;
grant execute on function app.has_branch(uuid) to authenticated, service_role;
grant execute on function app.jwt() to authenticated, service_role;

-- ===========================================================================
-- Grants
-- ===========================================================================
-- anon gets nothing: this product has no anonymous surface. Every caller is a
-- known member of staff, and an unauthenticated request should fail at the
-- door rather than at a policy.
revoke all on all tables in schema public from anon, authenticated;
grant select, insert, update, delete on all tables in schema public to authenticated;
grant all on all tables in schema public to service_role;

-- ===========================================================================
-- Enable row-level security and apply the tenant policies
-- ===========================================================================
-- Generated in a loop rather than written out 88 times: a hand-written list is
-- a list somebody forgets to add to. The coverage assertions in
-- db/tests/0010_isolation.sql fail the build if any table ends up without RLS
-- enabled or without a policy, so the loop cannot silently miss one.
do $$
declare
    t record;
    predicate text;
begin
    for t in
        select c.relname,
               exists (
                   select 1 from pg_attribute a
                   where a.attrelid = c.oid and a.attname = 'branch_id'
                     and a.attnum > 0 and not a.attisdropped
               ) as has_branch
        from pg_class c
        join pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'public' and c.relkind = 'r'
        order by c.relname
    loop
        execute format('alter table public.%I enable row level security', t.relname);

        if t.relname = 'business' then
            -- The tenant row itself: reachable only by its own members.
            predicate := 'id = app.current_business_id()';
        elsif t.has_branch then
            predicate := 'business_id = app.current_business_id() and app.has_branch(branch_id)';
        else
            predicate := 'business_id = app.current_business_id()';
        end if;

        execute format('drop policy if exists %I on public.%I', t.relname || '_tenant', t.relname);
        execute format(
            'create policy %I on public.%I for all to authenticated using (%s) with check (%s)',
            t.relname || '_tenant', t.relname, predicate, predicate);
    end loop;
end $$;

-- ===========================================================================
-- audit_event is append-only for everyone (BR-13)
-- ===========================================================================
-- The general policy above would allow an authenticated caller to update or
-- delete an audit row. Replacing it with insert and select policies removes
-- that possibility at the policy layer; WP-4 additionally revokes the grants,
-- so the guarantee holds in two independent ways.
drop policy if exists audit_event_tenant on public.audit_event;

create policy audit_event_insert on public.audit_event
    for insert to authenticated
    with check (business_id = app.current_business_id() and app.has_branch(branch_id));

create policy audit_event_select on public.audit_event
    for select to authenticated
    using (business_id = app.current_business_id() and app.has_branch(branch_id));

-- Belt and braces: no policy permits it, and the privilege is withdrawn as
-- well. Either alone would be enough; both together mean a future migration
-- that accidentally adds a permissive policy still cannot open the hole.
revoke update, delete on public.audit_event from authenticated;

comment on table audit_event is
    'Append-only record of who changed what, when, from where (BR-13). No update or delete policy exists for any application role, and the privileges are revoked besides.';
