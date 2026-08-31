-- Proves migration 0010 does what it claims: a table created after it exists is
-- not automatically reachable by the anonymous role.
--
-- This is the failure mode that would otherwise appear in P1 and stay invisible
-- until someone read a privilege listing.

create table public.future_table_probe (
    id          uuid primary key default gen_random_uuid(),
    business_id uuid not null references business(id),
    created_at  timestamptz not null default now(),
    created_by  uuid,
    updated_at  timestamptz not null default now(),
    updated_by  uuid,
    deleted_at  timestamptz,
    row_version integer not null default 1
);

select dhaaga_test.eq(
    (select count(*)::int from information_schema.role_table_grants
     where grantee = 'anon' and table_schema = 'public' and table_name = 'future_table_probe'),
    0, 'a table created after migration 0010 grants nothing to the anonymous role');

select dhaaga_test.eq(
    (select count(*)::int from information_schema.role_table_grants
     where grantee = 'authenticated' and table_schema = 'public' and table_name = 'future_table_probe'),
    0, 'nor to authenticated - a new table is unreachable until its migration grants access explicitly');

-- The probe table is rolled back with the test transaction, so it never exists
-- in a real database. It is also why the conventions and isolation suites are
-- unaffected by it.
