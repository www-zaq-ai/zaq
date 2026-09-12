-- Shared capability validation and ACLs. Runs inside the entrypoint transaction.
DO $$
DECLARE
  inputs record;
  schema_name text;
  creator text;
  column_grant record;
BEGIN
  SELECT * INTO inputs FROM zaq_bootstrap_input;
  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_extension e
    JOIN pg_catalog.pg_depend d ON d.refobjid = e.oid
      AND d.refclassid = 'pg_catalog.pg_extension'::regclass
      AND d.classid = 'pg_catalog.pg_type'::regclass AND d.deptype = 'e'
    WHERE e.extname = 'vector' AND d.objid = pg_catalog.to_regtype('public.halfvec')
  ) THEN
    RAISE EXCEPTION 'ZAQ requires vector >= 0.7.0 with halfvec in public'
      USING HINT = 'Have the DBA upgrade the package/extension or reconcile its schema; bootstrap never upgrades or relocates extensions.';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_extension
             WHERE extname IN ('vector', 'pg_search') AND extowner <> (SELECT oid FROM pg_roles WHERE rolname = current_user)) THEN
    RAISE EXCEPTION 'Required extensions must belong to the executing DBA';
  END IF;

  EXECUTE format('ALTER DATABASE %I OWNER TO %I', current_database(), inputs.owner_name);
  EXECUTE format('REVOKE ALL ON DATABASE %I FROM PUBLIC, %I', current_database(), inputs.reader_name);
  EXECUTE format('GRANT CONNECT ON DATABASE %I TO %I', current_database(), inputs.reader_name);
  -- PostgreSQL 15+ makes public follow the database owner through this role.
  ALTER SCHEMA public OWNER TO pg_database_owner;

  FOR schema_name IN SELECT nspname FROM pg_namespace
    WHERE nspname <> 'information_schema' AND nspname !~ '^pg_'
  LOOP
    EXECUTE format('REVOKE ALL ON SCHEMA %I FROM PUBLIC, %I', schema_name, inputs.reader_name);
    EXECUTE format('GRANT USAGE ON SCHEMA %I TO %I', schema_name, inputs.reader_name);
    EXECUTE format('GRANT USAGE, CREATE ON SCHEMA %I TO %I', schema_name, inputs.owner_name);
    EXECUTE format('REVOKE ALL ON ALL TABLES IN SCHEMA %I FROM PUBLIC, %I', schema_name, inputs.reader_name);
    EXECUTE format('GRANT SELECT ON ALL TABLES IN SCHEMA %I TO %I', schema_name, inputs.reader_name);
    EXECUTE format('REVOKE ALL ON ALL SEQUENCES IN SCHEMA %I FROM PUBLIC, %I', schema_name, inputs.reader_name);
    EXECUTE format('GRANT SELECT ON ALL SEQUENCES IN SCHEMA %I TO %I', schema_name, inputs.reader_name);
    -- SELECT alone must not expose write-capable application/extension routines.
    EXECUTE format('REVOKE ALL ON ALL ROUTINES IN SCHEMA %I FROM PUBLIC, %I', schema_name, inputs.reader_name);
    EXECUTE format('GRANT EXECUTE ON ALL ROUTINES IN SCHEMA %I TO %I', schema_name, inputs.owner_name);
  END LOOP;

  -- Table-level REVOKE does not remove pre-existing column-level privileges.
  FOR column_grant IN
    SELECT n.nspname, c.relname, a.attname
    FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE a.attacl IS NOT NULL AND n.nspname <> 'information_schema' AND n.nspname !~ '^pg_'
  LOOP
    EXECUTE format('REVOKE ALL (%I) ON TABLE %I.%I FROM PUBLIC, %I',
      column_grant.attname, column_grant.nspname, column_grant.relname, inputs.reader_name);
  END LOOP;

  -- Global defaults cover tables in future schemas as well as runtime recreation.
  -- Other object-creating roles must receive equivalent defaults explicitly.
  FOREACH creator IN ARRAY ARRAY[inputs.owner_name, current_user::text]
  LOOP
    EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE %I REVOKE ALL ON SCHEMAS FROM PUBLIC, %I', creator, inputs.reader_name);
    EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE %I REVOKE ALL ON TABLES FROM PUBLIC, %I', creator, inputs.reader_name);
    EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE %I REVOKE ALL ON SEQUENCES FROM PUBLIC, %I', creator, inputs.reader_name);
    EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE %I REVOKE ALL ON FUNCTIONS FROM PUBLIC, %I', creator, inputs.reader_name);
    FOR schema_name IN SELECT nspname FROM pg_namespace
      WHERE nspname <> 'information_schema' AND nspname !~ '^pg_'
    LOOP
      EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA %I REVOKE ALL ON TABLES FROM PUBLIC, %I', creator, schema_name, inputs.reader_name);
      EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA %I REVOKE ALL ON SEQUENCES FROM PUBLIC, %I', creator, schema_name, inputs.reader_name);
      EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA %I REVOKE ALL ON FUNCTIONS FROM PUBLIC, %I', creator, schema_name, inputs.reader_name);
    END LOOP;
    EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE %I GRANT USAGE ON SCHEMAS TO %I', creator, inputs.reader_name);
    EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE %I GRANT SELECT ON TABLES TO %I', creator, inputs.reader_name);
    EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE %I GRANT SELECT ON SEQUENCES TO %I', creator, inputs.reader_name);
  END LOOP;
END;
$$;

COMMIT;
\echo 'ZAQ database provisioned. Configure ZAQ with the owner login, then run migrations.'
