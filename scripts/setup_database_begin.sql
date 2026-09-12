-- Shared psql bootstrap preflight. Invoke through an engine entrypoint with -X.
-- Passwords are environment inputs, never command-line arguments.
\set ON_ERROR_STOP on
\set ECHO none
\set VERBOSITY terse
\set zaq_owner_password ''
\set zaq_reader_password ''
\getenv zaq_owner_password ZAQ_OWNER_PASSWORD
\getenv zaq_reader_password ZAQ_READER_PASSWORD
\if :{?zaq_database}
\else
  \echo 'Required: --set zaq_database=NAME'
  DO $$ BEGIN RAISE EXCEPTION 'Missing bootstrap input'; END $$;
\endif
\if :{?zaq_owner}
\else
  \echo 'Required: --set zaq_owner=NAME'
  DO $$ BEGIN RAISE EXCEPTION 'Missing bootstrap input'; END $$;
\endif
\if :{?zaq_reader}
\else
  \echo 'Required: --set zaq_reader=NAME'
  DO $$ BEGIN RAISE EXCEPTION 'Missing bootstrap input'; END $$;
\endif
SELECT rolsuper AS zaq_is_dba FROM pg_roles WHERE rolname = current_user \gset
\if :zaq_is_dba
\else
  \echo 'Bootstrap requires an executing superuser DBA.'
  DO $$ BEGIN RAISE EXCEPTION 'Bootstrap requires superuser'; END $$;
\endif

-- Avoid logging credential-bearing statements in ordinary PostgreSQL logs.
-- External audit tooling must also redact secrets; never enable psql echo.
SET log_statement = 'none';
SET log_min_duration_statement = -1;
SET log_min_duration_sample = -1;
SET log_min_error_statement = 'panic';

SELECT current_user AS zaq_dba,
       length(:'zaq_database') > 0 AND octet_length(:'zaq_database') <= 63
       AND :'zaq_database' NOT IN ('postgres', 'template0', 'template1', current_database())
       AND length(:'zaq_owner') > 0 AND octet_length(:'zaq_owner') <= 63
       AND length(:'zaq_reader') > 0 AND octet_length(:'zaq_reader') <= 63
       AND :'zaq_owner' !~ '^pg_' AND :'zaq_reader' !~ '^pg_'
       AND :'zaq_owner' <> :'zaq_reader'
       AND :'zaq_owner' <> current_user AND :'zaq_reader' <> current_user
       AND length(:'zaq_owner_password') > 0 AND length(:'zaq_reader_password') > 0
       AS zaq_valid_inputs
\gset
\if :zaq_valid_inputs
\else
  \echo 'Invalid bootstrap inputs: use a target distinct from maintenance/system databases, distinct non-DBA role names (1-63 bytes), and nonempty passwords.'
  DO $$ BEGIN RAISE EXCEPTION 'Invalid bootstrap inputs'; END $$;
\endif

SELECT NOT EXISTS (
  SELECT 1 FROM pg_database
  WHERE datname = :'zaq_database'
    AND (pg_get_userbyid(datdba) NOT IN (current_user, :'zaq_owner') OR datistemplate)
) AS zaq_owner_allowed
\gset
\if :zaq_owner_allowed
\else
  \echo 'Refusing database with unexpected owner (must be executing DBA or requested owner).'
  DO $$ BEGIN RAISE EXCEPTION 'Refusing database with unexpected owner'; END $$;
\endif

-- Database creation cannot be transactional. A failed later step leaves a
-- DBA-owned database that can safely be retried; it never leaves partial roles.
SELECT format('CREATE DATABASE %I TEMPLATE template0', :'zaq_database')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'zaq_database')
\gexec

-- Use a quoted conninfo dbname, not a bare name that libpq could interpret as a URI.
SELECT 'dbname=' || chr(39) || replace(replace(:'zaq_database', chr(92), chr(92) || chr(92)), chr(39), chr(92) || chr(39)) || chr(39) AS zaq_connection
\gset
\connect -reuse-previous=on :"zaq_connection"
SET log_statement = 'none';
SET log_min_duration_statement = -1;
SET log_min_duration_sample = -1;
SET log_min_error_statement = 'panic';
SET password_encryption = 'scram-sha-256';
SET search_path = pg_catalog, public;

BEGIN;
-- Serialize cooperating bootstrap runs in this database, then recheck guards.
SELECT pg_advisory_xact_lock(731946284);
CREATE TEMP TABLE zaq_bootstrap_input ON COMMIT DROP AS
SELECT :'zaq_owner'::text AS owner_name, :'zaq_reader'::text AS reader_name,
       :'zaq_owner_password'::text AS owner_password,
       :'zaq_reader_password'::text AS reader_password;
\unset zaq_owner_password
\unset zaq_reader_password

DO $$
DECLARE
  inputs record;
  candidate record;
BEGIN
  SELECT * INTO inputs FROM zaq_bootstrap_input;
  IF EXISTS (
    SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relname = 'schema_migrations' AND n.nspname NOT LIKE 'pg_temp_%'
  ) THEN
    RAISE EXCEPTION 'Refusing database: schema_migrations exists';
  END IF;
  IF (SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = current_database())
      NOT IN (current_user, inputs.owner_name) THEN
    RAISE EXCEPTION 'Refusing database with unexpected owner';
  END IF;

  FOR candidate IN SELECT * FROM pg_roles WHERE rolname IN (inputs.owner_name, inputs.reader_name)
  LOOP
    IF candidate.rolsuper OR candidate.rolcreatedb OR candidate.rolcreaterole
       OR candidate.rolreplication OR candidate.rolbypassrls
       OR EXISTS (SELECT 1 FROM pg_auth_members WHERE member = candidate.oid OR roleid = candidate.oid)
       OR EXISTS (SELECT 1 FROM pg_shdepend WHERE refclassid = 'pg_authid'::regclass
         AND refobjid = candidate.oid AND dbid <> 0
         AND dbid <> (SELECT oid FROM pg_database WHERE datname = current_database()))
       OR EXISTS (SELECT 1 FROM pg_database WHERE datdba = candidate.oid
         AND (datname <> current_database() OR candidate.rolname = inputs.reader_name))
       OR (candidate.rolname = inputs.reader_name AND EXISTS (
         SELECT 1 FROM pg_shdepend WHERE refclassid = 'pg_authid'::regclass
           AND refobjid = candidate.oid AND deptype = 'o')) THEN
      RAISE EXCEPTION 'Refusing unsafe or shared existing role: %', candidate.rolname;
    END IF;
  END LOOP;

  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = inputs.owner_name) THEN
    EXECUTE format('CREATE ROLE %I', inputs.owner_name);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = inputs.reader_name) THEN
    EXECUTE format('CREATE ROLE %I', inputs.reader_name);
  END IF;
  EXECUTE format('ALTER ROLE %I LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS NOINHERIT PASSWORD %L VALID UNTIL %L', inputs.owner_name, inputs.owner_password, 'infinity');
  EXECUTE format('ALTER ROLE %I LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS NOINHERIT PASSWORD %L VALID UNTIL %L', inputs.reader_name, inputs.reader_password, 'infinity');
END;
$$;
