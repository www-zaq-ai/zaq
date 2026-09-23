-- Run as a DBA/provider administrator against the target ZAQ database:
-- psql -X --set ON_ERROR_STOP=1 --dbname "$DB_ADMIN_URL" --file scripts/setup_paradedb_extensions.sql
-- The server must provide pgvector >= 0.7.0 and ParadeDB pg_search packages.
-- This script does not create databases/roles or upgrade existing extensions.
BEGIN;

CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA public;
CREATE EXTENSION IF NOT EXISTS pg_search;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_extension e
    JOIN pg_catalog.pg_depend d ON d.refobjid = e.oid
      AND d.refclassid = 'pg_catalog.pg_extension'::regclass
      AND d.classid = 'pg_catalog.pg_type'::regclass AND d.deptype = 'e'
    WHERE e.extname = 'vector' AND d.objid = pg_catalog.to_regtype('public.halfvec')
  ) THEN
    RAISE EXCEPTION 'ZAQ requires vector >= 0.7.0 with halfvec in public'
      USING HINT = 'Have the DBA upgrade the server package and existing vector extension, or reconcile its schema. This script deliberately does not upgrade or relocate extensions.';
  END IF;
END;
$$;

-- Match the application's functional backend probe; installation alone is not enough.
SELECT 1 FROM paradedb.version_info();

COMMIT;
