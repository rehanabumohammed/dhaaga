-- 0001 · Extensions
--
-- Only extensions available on Supabase Cloud are used, so that what runs
-- locally is what runs in production (ADR-0001).
--   pgcrypto  - gen_random_uuid() for server-side key generation. Client-side
--               keys are generated in the app; the server needs its own for
--               system-created rows.
--   pg_trgm   - trigram similarity, backing customer name search and the
--               duplicate-detection scoring in §2.3 of the blueprint.
--   btree_gist- exclusion constraints spanning scalar and range columns; needed
--               later for number-lease non-overlap and capacity reservations.

create extension if not exists pgcrypto;
create extension if not exists pg_trgm;
create extension if not exists btree_gist;
