-- Explicit, one-shot adoption of an already migrated and manually provisioned DB.
-- No bootstrap/repair/migrations: receipt is the only persistent write.
\set ON_ERROR_STOP on
\set ECHO none
SELECT rolsuper AS is_dba FROM pg_roles WHERE rolname = current_user \gset
\if :is_dba
\else
  DO $$ BEGIN RAISE EXCEPTION 'Adoption requires a superuser DBA'; END $$;
\endif
SELECT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'zaq_database') AS target_exists \gset
\if :target_exists
\else
  DO $$ BEGIN RAISE EXCEPTION 'Adoption requires an existing database'; END $$;
\endif
SELECT 'dbname=' || chr(39) || replace(replace(:'zaq_database', chr(92), chr(92) || chr(92)), chr(39), chr(92) || chr(39)) || chr(39) AS target \gset
\connect -reuse-previous=on :"target"
SET search_path = pg_catalog, public;
BEGIN;
SELECT pg_advisory_xact_lock(731946284);
\set zaq_already_connected true
\ir docker_database_status.sql
\ir docker_database_validate.sql
\ir docker_database_adopt_validate.sql
\if :zaq_provisioned
  -- Trusted matching receipt: validation only, no write.
\else
  \ir docker_database_receipt.sql
\endif
COMMIT;
