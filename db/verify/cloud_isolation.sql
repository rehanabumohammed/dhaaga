-- Dhaaga · cloud isolation check
--
-- Verifies the isolation guarantees against a deployed project and returns one
-- row per check with a verdict. Paste it whole into the Supabase SQL editor, or
-- run it with psql. It needs neither Python nor a local Postgres client.
--
-- It creates two businesses, three branches, two users and three orders; checks
-- what each user can reach while acting as the `authenticated` role; then throws
-- all of it away. The fixtures live inside a subtransaction that is deliberately
-- rolled back, so nothing survives. Results are held in memory, which is not
-- transactional, so they outlive the rollback.
--
-- Acting as `authenticated` is the whole point: it is the role Supabase's REST
-- layer connects as. A check run as the owner passes against a completely
-- unprotected database, which is the failure mode that makes a security check
-- worse than useless.
--
-- FAIL rows sort to the top. If any row reads FAIL, stop and report it.

create or replace function pg_temp.dhaaga_isolation_check()
returns table (check_name text, expected text, actual text, verdict text)
language plpgsql
as $fn$
declare
    names   text[] := '{}';
    expects text[] := '{}';
    actuals text[] := '{}';
    v       text;
    refused boolean;

    biz_a  uuid := '0a11a000-0000-0000-0000-0000000000a1';
    biz_b  uuid := '0b11b000-0000-0000-0000-0000000000b1';
    br_a1  uuid := '0a11a000-0000-0000-0000-0000000000a2';
    br_a2  uuid := '0a11a000-0000-0000-0000-0000000000a3';
    br_b1  uuid := '0b11b000-0000-0000-0000-0000000000b2';
    usr_a  uuid := '0a11a000-0000-0000-0000-0000000000a4';
    usr_b  uuid := '0b11b000-0000-0000-0000-0000000000b3';
    -- WP-7: the token subject is a Supabase Auth id, a different value from the
    -- application user's id. Kept distinct here so a deployment where the two
    -- were confused fails this check rather than passing by coincidence.
    aut_a  uuid := '0a11a000-0000-0000-0000-00000000aa04';
    aut_b  uuid := '0b11b000-0000-0000-0000-00000000bb03';
    rol_a  uuid := '0a11a000-0000-0000-0000-0000000000a5';
    rol_b  uuid := '0b11b000-0000-0000-0000-0000000000b4';
    cus_a  uuid := '0a11a000-0000-0000-0000-0000000000a6';
    cus_b  uuid := '0b11b000-0000-0000-0000-0000000000b5';
    cfg_a  uuid := '0a11a000-0000-0000-0000-0000000000a7';
    prm_a  uuid := '0a11a000-0000-0000-0000-0000000000a8';
begin
    -- Static checks: no fixtures needed.
    select count(*)::text into v from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity;
    names := names || ('rls · tables without row-level security')::text; expects := expects || ('0')::text; actuals := actuals || (v)::text;

    select count(*)::text into v from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind = 'r'
       and not exists (select 1 from pg_policy p where p.polrelid = c.oid);
    names := names || ('rls · tables without a policy')::text; expects := expects || ('0')::text; actuals := actuals || (v)::text;

    select count(*)::text into v from information_schema.role_table_grants
     where grantee = 'anon' and table_schema = 'public';
    names := names || ('exposure · anonymous role table privileges')::text; expects := expects || ('0')::text; actuals := actuals || (v)::text;

    -- A view runs with its owner's rights unless it says otherwise, which would
    -- take a caller straight past every policy underneath it. The table checks
    -- above cannot see this, because a view is not a table.
    select count(*)::text into v from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind = 'v'
       and coalesce(array_to_string(c.reloptions, ','), '') not like '%security_invoker=true%';
    names := names || ('exposure · views running with owner privileges')::text; expects := expects || ('0')::text; actuals := actuals || (v)::text;

    -- Live checks, inside a subtransaction that will be discarded.
    begin
        insert into business (id, legal_name) values (biz_a, 'Isolation check A'), (biz_b, 'Isolation check B');
        insert into branch (id, business_id, code, name) values
            (br_a1, biz_a, 'ISOA1', 'A one'), (br_a2, biz_a, 'ISOA2', 'A two'), (br_b1, biz_b, 'ISOB1', 'B one');
        insert into app_user (id, business_id, auth_user_id, full_name) values
            (usr_a, biz_a, aut_a, 'Isolation user A'), (usr_b, biz_b, aut_b, 'Isolation user B');
        insert into role (id, business_id, code, name) values
            (rol_a, biz_a, 'isocheck', 'Check'), (rol_b, biz_b, 'isocheck', 'Check');
        -- A real permission to try to grab. Without one the escalation check
        -- below would insert zero rows, fire no trigger, and pass vacuously.
        insert into permission (id, business_id, code, domain) values
            (prm_a, biz_a, 'isocheck.privilege', 'admin');
        insert into user_branch_role (business_id, user_id, branch_id, role_id) values
            (biz_a, usr_a, br_a1, rol_a), (biz_b, usr_b, br_b1, rol_b);
        insert into customer (id, business_id, display_name) values
            (cus_a, biz_a, 'Customer A'), (cus_b, biz_b, 'Customer B');
        insert into sales_order (business_id, branch_id, order_no, customer_id) values
            (biz_a, br_a1, 'ISO-A1', cus_a), (biz_a, br_a2, 'ISO-A2', cus_a), (biz_b, br_b1, 'ISO-B1', cus_b);
        -- WP-6 fixtures: a rule A's user is not permitted to change, and a
        -- sign-off belonging to B that A must not be able to ask about.
        insert into config_setting (id, business_id, key, category, scope, value_type,
                                    default_value, current_value, required_permission)
            values (cfg_a, biz_a, 'isocheck.buffer_days', 'production', 'business',
                    'integer', '1', '1', 'config.manage');
        insert into validation_signoff (business_id, domain, validated_by_name, validated_on, config_hash)
            values (biz_b, 'tax', 'B''s CA', current_date, app.config_hash('tax', biz_b));

        -- Become user A, who is granted branch A1 only.
        perform set_config('app.actor_id', '', true);
        perform set_config('request.jwt.claims',
                 json_build_object('sub', aut_a::text, 'role', 'authenticated')::text, true);
        set local role authenticated;

        select count(*)::text into v from customer where id = cus_b;
        names := names || ('isolation · A cannot see business B''s customer')::text; expects := expects || ('0')::text; actuals := actuals || (v)::text;

        select count(*)::text into v from customer where id = cus_a;
        names := names || ('isolation · A sees their own business''s customer')::text; expects := expects || ('1')::text; actuals := actuals || (v)::text;

        select count(*)::text into v from sales_order where order_no = 'ISO-A1';
        names := names || ('isolation · A sees the branch they are granted')::text; expects := expects || ('1')::text; actuals := actuals || (v)::text;

        select count(*)::text into v from sales_order where order_no = 'ISO-A2';
        names := names || ('isolation · A cannot see another branch of their own business')::text; expects := expects || ('0')::text; actuals := actuals || (v)::text;

        select count(*)::text into v from sales_order where order_no = 'ISO-B1';
        names := names || ('isolation · A cannot see business B''s orders')::text; expects := expects || ('0')::text; actuals := actuals || (v)::text;

        begin
            insert into customer (business_id, display_name) values (biz_b, 'Planted');
            refused := false;
        exception when insufficient_privilege then refused := true;
                  when others then refused := false;
        end;
        names := names || ('isolation · A cannot write into business B')::text;
        expects := expects || ('refused')::text;
        actuals := actuals || (case when refused then 'refused' else 'ALLOWED' end)::text;

        -- WP-7 · identity and authorization
        select coalesce(app.current_user_id()::text,'null') into v;
        names := names || ('identity · a token resolves to the application user')::text; expects := expects || (usr_a::text)::text; actuals := actuals || (v)::text;

        select (app.auth_uid() is distinct from app.current_user_id())::text into v;
        names := names || ('identity · the auth subject and the application user are different values')::text; expects := expects || ('true')::text; actuals := actuals || (v)::text;

        begin
            insert into role_permission (business_id, role_id, permission_id)
            values (biz_a, rol_a, prm_a);
            refused := false;
        exception when insufficient_privilege then refused := true;
                  when others then refused := false;
        end;
        names := names || ('identity · A cannot add a permission to their own role')::text;
        expects := expects || ('refused')::text;
        actuals := actuals || (case when refused then 'refused' else 'ALLOWED' end)::text;

        begin
            insert into user_branch_role (business_id, user_id, branch_id, role_id)
            values (biz_a, usr_a, br_a2, rol_a);
            refused := false;
        exception when insufficient_privilege then refused := true;
                  when others then refused := false;
        end;
        names := names || ('identity · nor grant themselves a branch they do not hold')::text;
        expects := expects || ('refused')::text;
        actuals := actuals || (case when refused then 'refused' else 'ALLOWED' end)::text;

        begin
            insert into permission (business_id, code, domain) values (biz_a, 'invented.superpower','admin');
            refused := false;
        exception when insufficient_privilege then refused := true;
                  when others then refused := false;
        end;
        names := names || ('identity · nor invent a permission')::text;
        expects := expects || ('refused')::text;
        actuals := actuals || (case when refused then 'refused' else 'ALLOWED' end)::text;

        begin
            perform 1 from user_credential;
            refused := false;
        exception when insufficient_privilege then refused := true;
                  when others then refused := false;
        end;
        names := names || ('identity · nor read the PIN credential table at all')::text;
        expects := expects || ('refused')::text;
        actuals := actuals || (case when refused then 'refused' else 'ALLOWED' end)::text;

        -- WP-6 · configuration is permission-gated and tenant-scoped
        select coalesce(app.config_int('isocheck.buffer_days')::text, 'null') into v;
        names := names || ('config · A resolves their own business''s rule')::text; expects := expects || ('1')::text; actuals := actuals || (v)::text;

        begin
            perform app.set_config_value('isocheck.buffer_days', '9'::jsonb);
            refused := false;
        exception when insufficient_privilege then refused := true;
                  when others then refused := false;
        end;
        names := names || ('config · A cannot change a rule they hold no permission for')::text;
        expects := expects || ('refused')::text;
        actuals := actuals || (case when refused then 'refused' else 'ALLOWED' end)::text;

        -- PostgreSQL searches the temporary schema first when pg_temp is not
        -- named in search_path, so an unpinned trigger can be pointed at a
        -- table of the caller's making and the permission check skipped. If the
        -- temporary table cannot even be created the attack cannot be staged,
        -- which is also a pass.
        begin
            execute 'create temp table config_setting (id uuid, required_permission text)';
            begin
                insert into config_version (business_id, setting_id, value, effective_from)
                values (biz_a, cfg_a, '9', now() + interval '90 days');
                refused := false;
            exception when insufficient_privilege then refused := true;
                      when others then refused := false;
            end;
            execute 'drop table pg_temp.config_setting';
        exception when others then refused := true;
        end;
        names := names || ('config · nor by shadowing config_setting through pg_temp')::text;
        expects := expects || ('refused')::text;
        actuals := actuals || (case when refused then 'refused' else 'ALLOWED' end)::text;

        begin
            perform app.validation_status('tax', biz_b);
            refused := false;
        exception when insufficient_privilege then refused := true;
                  when others then refused := false;
        end;
        names := names || ('config · A cannot read business B''s validation status')::text;
        expects := expects || ('refused')::text;
        actuals := actuals || (case when refused then 'refused' else 'ALLOWED' end)::text;

        -- A caller carrying no identity at all: the shape of a bare publishable key.
        perform set_config('request.jwt.claims', '', true);

        select count(*)::text into v from customer;
        names := names || ('isolation · a call with no identity reaches no customers')::text; expects := expects || ('0')::text; actuals := actuals || (v)::text;

        select count(*)::text into v from garment;
        names := names || ('isolation · and no production data')::text; expects := expects || ('0')::text; actuals := actuals || (v)::text;

        reset role;

        -- Audit immutability, checked as the owner. Policies and grants do not
        -- restrain an owner, so a pass here is the trigger doing its job.
        begin
            update audit_event set reason_code = 'tampered' where true;
            refused := false;
        exception when others then refused := true;
        end;
        names := names || ('audit · rows cannot be modified, even by the owner')::text;
        expects := expects || ('refused')::text;
        actuals := actuals || (case when refused then 'refused' else 'ALLOWED' end)::text;

        raise exception 'dhaaga_isolation_rollback';
    exception when others then
        reset role;
        if SQLERRM <> 'dhaaga_isolation_rollback' then
            names := names || ('suite · ran to completion')::text;
            expects := expects || ('yes')::text;
            actuals := actuals || (('ERROR: ' || SQLERRM))::text;
        end if;
    end;

    reset role;

    return query
    select n, e, a, case when e = a then 'PASS' else 'FAIL' end
    from unnest(names, expects, actuals) as t(n, e, a)
    order by case when e = a then 1 else 0 end, n;
end $fn$;

select * from pg_temp.dhaaga_isolation_check();
