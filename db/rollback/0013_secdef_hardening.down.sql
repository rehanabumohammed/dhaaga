-- Restores the pre-audit behaviour. Reintroduces a known tenant-isolation
-- bypass, so this is only ever appropriate while tearing the schema down.
drop function if exists app.assert_tenant_write(uuid, uuid);
drop function if exists app.set_request_context(uuid, text, text);

create or replace function app.current_user_id()
returns uuid language plpgsql stable as $$
declare claim text; override text;
begin
    override := nullif(current_setting('app.actor_id', true), '');
    if override is not null then return override::uuid; end if;
    claim := app.jwt() ->> 'sub';
    if claim is null or claim = '' then return null; end if;
    return claim::uuid;
exception when invalid_text_representation then return null;
end $$;

grant execute on function app.current_user_id() to authenticated, service_role;
grant execute on function app.set_context(uuid, uuid, text, text) to authenticated, service_role;
grant execute on function app.post_entry(uuid, uuid, text, uuid, text, jsonb, date) to authenticated, service_role;
grant execute on function app.reverse_journal_entry(uuid, text, text, date) to authenticated, service_role;
