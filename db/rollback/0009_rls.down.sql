-- Drop every tenant policy and disable row-level security.
do $$
declare t record;
begin
    for t in
        select c.relname from pg_class c
        join pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'public' and c.relkind = 'r'
    loop
        execute format('drop policy if exists %I on public.%I', t.relname || '_tenant', t.relname);
        execute format('alter table public.%I disable row level security', t.relname);
    end loop;
end $$;

drop policy if exists audit_event_insert on public.audit_event;
drop policy if exists audit_event_select on public.audit_event;

drop function if exists app.has_branch(uuid);
drop function if exists app.current_branch_ids();
drop function if exists app.current_business_id();

revoke all on all tables in schema public from anon, authenticated, service_role;
