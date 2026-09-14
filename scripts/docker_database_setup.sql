-- Automatic bootstrap: a receipt, never a migration ledger, permits restart.
\set ON_ERROR_STOP on
SELECT 'dbname=' || chr(39) || replace(replace(current_database(), chr(92), chr(92) || chr(92)), chr(39), chr(92) || chr(39)) || chr(39) AS maintenance \gset
SELECT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'zaq_database') AS target_exists \gset
\set zaq_provisioned false
\if :target_exists
  \ir docker_database_status.sql
\endif
\if :zaq_provisioned
  -- Existing installations are validation-only; never rotate supplied passwords.
\else
  \connect -reuse-previous=on :"maintenance"
  \set zaq_write_bootstrap_receipt true
  SELECT :'zaq_bootstrap_engine' = 'paradedb' AS use_paradedb \gset
  \if :use_paradedb
    \ir setup_paradedb_extensions.sql
  \else
    \ir setup_postgres_extensions.sql
  \endif
\endif
\ir docker_database_status.sql
\if :zaq_provisioned
  \ir docker_database_validate.sql
\else
  DO $$ BEGIN RAISE EXCEPTION 'Bootstrap receipt missing'; END $$;
\endif
