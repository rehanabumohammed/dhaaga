do $$
declare t record;
begin
    for t in select c.relname from pg_class c
             join pg_namespace n on n.oid = c.relnamespace
             where n.nspname = 'public' and c.relkind = 'r'
    loop
        execute format('drop trigger if exists %I on public.%I', 'zz_audit_' || t.relname, t.relname);
    end loop;
end $$;

drop trigger if exists zz_audit_event_immutable on audit_event;
drop function if exists app.audit_immutable();
drop function if exists app.attach_audit(text);
drop function if exists app.audit_row();
drop function if exists app.audit_ignored_columns();
drop function if exists app.current_source();
drop function if exists app.resolved_device_id();
drop function if exists app.current_reason_text();
drop function if exists app.set_context(uuid, uuid, text, text);
drop table if exists audit_reason_requirement;
