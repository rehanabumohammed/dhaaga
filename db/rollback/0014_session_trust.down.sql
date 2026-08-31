-- Restores the 0013 behaviour, which leaves the token-clearing override path
-- open. Only appropriate while tearing the schema down.
create or replace function app.current_user_id()
returns uuid language plpgsql stable as $$
declare claim text; override text;
begin
    claim := app.jwt() ->> 'sub';
    if claim is not null and claim <> '' then return claim::uuid; end if;
    override := nullif(current_setting('app.actor_id', true), '');
    if override is not null then return override::uuid; end if;
    return null;
exception when invalid_text_representation then return null;
end $$;

grant execute on function app.current_user_id() to authenticated, service_role;
drop function if exists app.session_is_trusted();
