-- Local developer extension setup. Uses the current libpq connection only.
\set ON_ERROR_STOP on
\set ECHO none

BEGIN;
SET search_path = pg_catalog, public;
\ir install_vector_extension.sql

SELECT EXISTS (
  SELECT 1 FROM pg_catalog.pg_available_extensions WHERE name = 'pg_search'
) AS zaq_pg_search_available
\gset

\if :zaq_pg_search_available
  \ir install_pg_search_extension.sql
\endif
COMMIT;

\if :zaq_pg_search_available
  \echo 'Database extensions ready: vector and pg_search.'
\else
  \echo 'Database extensions ready: vector; pg_search is unavailable, using native search.'
\endif
