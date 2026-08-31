-- Convention tests — the enforcement behind ADR-0004.
--
-- Every application table carries the same spine. Without a test this rots
-- within a phase: someone adds a table in a hurry, omits deleted_at, and six
-- weeks later a policy or a sync cursor silently misses rows. These assertions
-- name the offending tables rather than merely counting them, so a failure is
-- actionable without opening the schema.

-- Tables under test: every base table in the exposed schema.
create temporary view tables_under_test as
    select c.relname as table_name, c.oid
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'r';

-- Returns a comma-separated list of tables missing the named column.
create or replace function pg_temp.missing_column(col text)
returns text language sql stable as $fn$
    select coalesce(string_agg(t.table_name, ', ' order by t.table_name), '')
    from tables_under_test t
    where not exists (
        select 1 from pg_attribute a
        where a.attrelid = t.oid and a.attname = col and a.attnum > 0 and not a.attisdropped
    );
$fn$;

-- ---------------------------------------------------------------------------
-- 1. The standard spine
-- ---------------------------------------------------------------------------
select dhaaga_test.eq(pg_temp.missing_column('id'),          '', 'every table has id');
select dhaaga_test.eq(pg_temp.missing_column('business_id'), '', 'every table has business_id (AP-7)');
select dhaaga_test.eq(pg_temp.missing_column('created_at'),  '', 'every table has created_at');
select dhaaga_test.eq(pg_temp.missing_column('created_by'),  '', 'every table has created_by');
select dhaaga_test.eq(pg_temp.missing_column('updated_at'),  '', 'every table has updated_at');
select dhaaga_test.eq(pg_temp.missing_column('updated_by'),  '', 'every table has updated_by');
select dhaaga_test.eq(pg_temp.missing_column('deleted_at'),  '', 'every table has deleted_at (BR-19: soft delete only)');
select dhaaga_test.eq(pg_temp.missing_column('row_version'), '', 'every table has row_version (optimistic concurrency, §5.2)');

-- ---------------------------------------------------------------------------
-- 2. Types are right
-- ---------------------------------------------------------------------------
select dhaaga_test.eq(
    coalesce((select string_agg(t.table_name || '.' || a.attname, ', ' order by t.table_name)
              from tables_under_test t
              join pg_attribute a on a.attrelid = t.oid
              where a.attname in ('id','business_id','created_by','updated_by')
                and a.attnum > 0 and not a.attisdropped
                and format_type(a.atttypid, null) <> 'uuid'), ''),
    '', 'id, business_id and actor columns are uuid');

select dhaaga_test.eq(
    coalesce((select string_agg(t.table_name || '.' || a.attname, ', ' order by t.table_name)
              from tables_under_test t
              join pg_attribute a on a.attrelid = t.oid
              where a.attnum > 0 and not a.attisdropped
                and format_type(a.atttypid, null) = 'timestamp without time zone'), ''),
    '', 'no naive timestamps anywhere - every point in time is timestamptz');

-- ---------------------------------------------------------------------------
-- 3. Keys and integrity
-- ---------------------------------------------------------------------------
select dhaaga_test.eq(
    coalesce((select string_agg(t.table_name, ', ' order by t.table_name)
              from tables_under_test t
              where not exists (
                  select 1 from pg_constraint c
                  where c.conrelid = t.oid and c.contype = 'p'
                    and c.conkey = array[(select a.attnum from pg_attribute a
                                          where a.attrelid = t.oid and a.attname = 'id')]
              )), ''),
    '', 'every table has a single-column primary key on id');

-- business_id points at the tenant on every table except business itself,
-- where it is a generated mirror of the primary key.
select dhaaga_test.eq(
    coalesce((select string_agg(t.table_name, ', ' order by t.table_name)
              from tables_under_test t
              where t.table_name <> 'business'
                and not exists (
                  select 1 from pg_constraint c
                  join pg_attribute a on a.attrelid = t.oid and a.attnum = any(c.conkey)
                  where c.conrelid = t.oid and c.contype = 'f'
                    and a.attname = 'business_id'
                    and c.confrelid = 'business'::regclass
              )), ''),
    '', 'business_id is a foreign key to business on every table');

-- ---------------------------------------------------------------------------
-- 4. Triggers and documentation
-- ---------------------------------------------------------------------------
select dhaaga_test.eq(
    coalesce((select string_agg(t.table_name, ', ' order by t.table_name)
              from tables_under_test t
              where not exists (
                  select 1 from pg_trigger g
                  where g.tgrelid = t.oid and not g.tgisinternal
                    and g.tgname = '00_touch_row_' || t.table_name
              )), ''),
    '', 'every table has the standard row-maintenance trigger');

select dhaaga_test.eq(
    coalesce((select string_agg(t.table_name, ', ' order by t.table_name)
              from tables_under_test t
              where obj_description(t.oid, 'pg_class') is null), ''),
    '', 'every table carries a comment explaining what it is for');

-- ---------------------------------------------------------------------------
-- 5. Money is never floating point (BR-04 depends on exact arithmetic)
-- ---------------------------------------------------------------------------
select dhaaga_test.eq(
    coalesce((select string_agg(t.table_name || '.' || a.attname, ', ' order by t.table_name)
              from tables_under_test t
              join pg_attribute a on a.attrelid = t.oid
              where a.attnum > 0 and not a.attisdropped
                and format_type(a.atttypid, null) in ('real','double precision')), ''),
    '', 'no floating point columns anywhere in the schema');

-- ---------------------------------------------------------------------------
-- 6. NULLS NOT DISTINCT is never applied to a nullable business column
-- ---------------------------------------------------------------------------
-- Found in WP-2: `unique nulls not distinct (business_id, phone_e164, deleted_at)`
-- makes two people who have no phone number collide with each other. The intent
-- was only ever to make soft-deleted rows distinguishable; the correct shape for
-- that is a partial unique index with a `where deleted_at is null` predicate.
-- This assertion stops the pattern reappearing.
select dhaaga_test.eq(
    coalesce((select string_agg(distinct c.conrelid::regclass::text || '.' || c.conname, ', ')
              from pg_constraint c
              join pg_namespace n on n.oid = c.connamespace
              join pg_attribute a on a.attrelid = c.conrelid and a.attnum = any(c.conkey)
              where n.nspname = 'public' and c.contype = 'u'
                and pg_get_constraintdef(c.oid) ilike '%nulls not distinct%'
                and not a.attnotnull
                and a.attname <> 'deleted_at'), ''),
    '', 'no unique constraint treats a nullable business column as NULLS NOT DISTINCT');
