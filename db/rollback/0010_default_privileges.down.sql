-- Restores Supabase's permissive default. Only appropriate when tearing the
-- whole schema down; never on a live project.
do $$
begin
    if exists (select 1 from pg_roles where rolname = 'anon') then
        execute 'alter default privileges in schema public grant all on tables to anon';
        execute 'alter default privileges in schema public grant all on tables to authenticated';
    end if;
end $$;
comment on schema public is null;
