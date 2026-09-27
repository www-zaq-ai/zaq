-- Preview by default. Explicit zaq_apply=true transfers postgres-owned application
-- objects in public, repairs ACLs with the canonical setup finish script, and commits.
\set ON_ERROR_STOP on
\set ECHO none
SELECT rolsuper AS is_dba FROM pg_roles WHERE rolname = current_user \gset
\if :is_dba
\else
  DO $$ BEGIN RAISE EXCEPTION 'Legacy ownership repair requires a superuser DBA'; END $$;
\endif
SELECT :'zaq_database' NOT IN ('postgres', 'template0', 'template1', current_database())
  AND :'zaq_owner' <> :'zaq_reader' AND :'zaq_owner' <> current_user
  AND :'zaq_reader' <> current_user
  AND EXISTS (SELECT 1 FROM pg_database WHERE datname = :'zaq_database')
  AND EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'zaq_owner' AND NOT rolsuper)
  AND EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'zaq_reader' AND NOT rolsuper)
  AS valid_target \gset
\if :valid_target
\else
  DO $$ BEGIN RAISE EXCEPTION 'Expected an existing application database and two distinct non-superuser roles'; END $$;
\endif
SELECT 'dbname=' || chr(39) || replace(replace(:'zaq_database', chr(92), chr(92) || chr(92)), chr(39), chr(92) || chr(39)) || chr(39) AS target \gset
\connect -reuse-previous=on :"target"
SET search_path = pg_catalog, public;
CREATE TEMP TABLE zaq_legacy_input AS
  SELECT :'zaq_owner'::text AS owner_name, :'zaq_reader'::text AS reader_name,
         current_user::text AS dba_name;

-- Refuse to infer ZAQ ownership for other roles or custom schemas. DBA-owned
-- extension members (pgvector/ParadeDB) are excluded by pg_depend below.
DO $$
DECLARE
  inputs record;
  invalid_type text;
BEGIN
  SELECT * INTO inputs FROM zaq_legacy_input;
  IF to_regnamespace('zaq_bootstrap') IS NOT NULL THEN
    RAISE EXCEPTION 'Receipt schema already exists; do not run legacy repair';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE c.relname = 'schema_migrations' AND n.nspname = 'public') THEN
    RAISE EXCEPTION 'Expected a migrated ZAQ database with public.schema_migrations';
  END IF;
  IF (SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = current_database())
      NOT IN (inputs.dba_name, inputs.owner_name) THEN
    RAISE EXCEPTION 'Database is owned by an unexpected role';
  END IF;
  IF (SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'public')
      NOT IN (inputs.dba_name, inputs.owner_name, 'pg_database_owner') THEN
    RAISE EXCEPTION 'Public schema is owned by an unexpected role';
  END IF;
  SELECT format('%I.%I', n.nspname, t.typname) INTO invalid_type
    FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
    WHERE n.nspname = 'public' AND t.typtype IN ('d', 'e', 'r', 'm')
      AND pg_get_userbyid(t.typowner) NOT IN (inputs.dba_name, inputs.owner_name)
      AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_type'::regclass
        AND d.objid = t.oid AND d.deptype = 'e')
    LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION 'Application type owned by another role needs manual review: %', invalid_type;
  END IF;
  SELECT format('%I.%I', n.nspname, t.typname) INTO invalid_type
    FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
    WHERE n.nspname = 'public' AND t.typtype = 'm'
      AND pg_get_userbyid(t.typowner) = inputs.dba_name
      AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_type'::regclass
        AND d.objid = t.oid AND d.deptype = 'e')
      AND NOT EXISTS (SELECT 1 FROM pg_range r JOIN pg_type base ON base.oid = r.rngtypid
        WHERE r.rngmultitypid = t.oid AND base.typnamespace = t.typnamespace
          AND pg_get_userbyid(base.typowner) = inputs.dba_name)
    LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION 'Standalone DBA-owned multirange needs manual review: %', invalid_type;
  END IF;
  IF EXISTS (
    SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname <> 'public' AND n.nspname <> 'information_schema'
      AND n.nspname !~ '^pg_' AND c.relkind IN ('r', 'p', 'v', 'm', 'f', 'S')
      AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_class'::regclass
        AND d.objid = c.oid AND d.deptype = 'e')
  ) OR EXISTS (
    SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p', 'v', 'm', 'f', 'S')
      AND pg_get_userbyid(c.relowner) NOT IN (inputs.dba_name, inputs.owner_name)
      AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_class'::regclass
        AND d.objid = c.oid AND d.deptype = 'e')
  ) THEN
    RAISE EXCEPTION 'Found non-extension objects in custom schemas or owned by another role; review manually';
  END IF;
  IF EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND pg_get_userbyid(p.proowner) NOT IN (inputs.dba_name, inputs.owner_name)
      AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_proc'::regclass
        AND d.objid = p.oid AND d.deptype = 'e')
  ) THEN
    RAISE EXCEPTION 'Application routines owned by another role need manual review';
  END IF;
END;
$$;

-- The preview names the only database objects whose owner will change. Extension
-- objects are never reassigned; do not use REASSIGN OWNED BY postgres.
SELECT 'database' AS object_kind, current_database() AS object_name
WHERE (SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = current_database()) = current_user
UNION ALL
SELECT 'schema', 'public'
WHERE (SELECT nspowner FROM pg_namespace WHERE nspname = 'public')
  <> (SELECT oid FROM pg_roles WHERE rolname = 'pg_database_owner')
UNION ALL
SELECT CASE t.typtype WHEN 'e' THEN 'enum' WHEN 'd' THEN 'domain'
  WHEN 'r' THEN 'range' ELSE 'dependent multirange' END,
  format('%I.%I', n.nspname, t.typname)
    || CASE WHEN t.typtype = 'd' THEN ' (base: ' || format_type(t.typbasetype, t.typtypmod) || ')'
            WHEN t.typtype = 'm' THEN ' (range: ' || (
              SELECT format('%I.%I', rn.nspname, base.typname)
              FROM pg_range r JOIN pg_type base ON base.oid = r.rngtypid
                JOIN pg_namespace rn ON rn.oid = base.typnamespace
              WHERE r.rngmultitypid = t.oid) || ')'
            ELSE '' END
FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
WHERE n.nspname = 'public' AND t.typtype IN ('d', 'e', 'r', 'm')
  AND pg_get_userbyid(t.typowner) = current_user
  AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_type'::regclass
    AND d.objid = t.oid AND d.deptype = 'e')
UNION ALL
SELECT CASE c.relkind WHEN 'S' THEN 'sequence' WHEN 'v' THEN 'view'
  WHEN 'm' THEN 'materialized view' WHEN 'f' THEN 'foreign table' ELSE 'table' END,
  format('%I.%I', n.nspname, c.relname)
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p', 'v', 'm', 'f', 'S')
  AND pg_get_userbyid(c.relowner) = current_user
  AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_class'::regclass
    AND d.objid = c.oid AND d.deptype = 'e')
UNION ALL
SELECT CASE p.prokind WHEN 'p' THEN 'procedure' WHEN 'a' THEN 'aggregate' ELSE 'function' END,
  format('%I.%I(%s)', n.nspname, p.proname, pg_get_function_identity_arguments(p.oid))
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND pg_get_userbyid(p.proowner) = current_user
  AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_proc'::regclass
    AND d.objid = p.oid AND d.deptype = 'e')
ORDER BY 1, 2;

\if :zaq_apply
  BEGIN;
  SELECT pg_advisory_xact_lock(731946284);
  -- The canonical ACL script expects an input table and owns the final COMMIT.
  CREATE TEMP TABLE zaq_bootstrap_input ON COMMIT DROP AS
    SELECT owner_name, reader_name FROM zaq_legacy_input;
  DO $$
  DECLARE
    inputs record;
    candidate record;
    statement text;
  BEGIN
    SELECT * INTO inputs FROM zaq_legacy_input;
    EXECUTE format('ALTER DATABASE %I OWNER TO %I', current_database(), inputs.owner_name);
    ALTER SCHEMA public OWNER TO pg_database_owner;
    FOR candidate IN
      SELECT t.oid, t.typname, t.typtype FROM pg_type t
        JOIN pg_namespace n ON n.oid = t.typnamespace
      WHERE n.nspname = 'public' AND t.typtype IN ('e', 'r', 'd')
        AND pg_get_userbyid(t.typowner) = inputs.dba_name
        AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_type'::regclass
          AND d.objid = t.oid AND d.deptype = 'e')
      ORDER BY CASE t.typtype WHEN 'e' THEN 0 WHEN 'r' THEN 1 ELSE 2 END
    LOOP
      statement := CASE candidate.typtype WHEN 'd' THEN 'ALTER DOMAIN' ELSE 'ALTER TYPE' END;
      EXECUTE format('%s %I.%I OWNER TO %I', statement, 'public', candidate.typname,
        inputs.owner_name);
    END LOOP;
    IF EXISTS (
      SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
      WHERE n.nspname = 'public' AND t.typtype = 'm'
        AND pg_get_userbyid(t.typowner) = inputs.dba_name
        AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_type'::regclass
          AND d.objid = t.oid AND d.deptype = 'e')
    ) THEN
      RAISE EXCEPTION 'Multirange ownership was not transferred with its range; rolling back';
    END IF;
    FOR candidate IN
      SELECT c.oid, n.nspname, c.relname, c.relkind
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p', 'v', 'm', 'f', 'S')
        AND pg_get_userbyid(c.relowner) = inputs.dba_name
        AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_class'::regclass
          AND d.objid = c.oid AND d.deptype = 'e')
      ORDER BY CASE c.relkind WHEN 'S' THEN 1 ELSE 0 END
    LOOP
      statement := CASE candidate.relkind WHEN 'S' THEN 'ALTER SEQUENCE'
        WHEN 'v' THEN 'ALTER VIEW' WHEN 'm' THEN 'ALTER MATERIALIZED VIEW'
        WHEN 'f' THEN 'ALTER FOREIGN TABLE' ELSE 'ALTER TABLE' END;
      EXECUTE format('%s %I.%I OWNER TO %I', statement, candidate.nspname,
        candidate.relname, inputs.owner_name);
    END LOOP;
    FOR candidate IN
      SELECT p.oid, p.proname, p.prokind FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public' AND pg_get_userbyid(p.proowner) = inputs.dba_name
        AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_proc'::regclass
          AND d.objid = p.oid AND d.deptype = 'e')
    LOOP
      statement := CASE candidate.prokind WHEN 'p' THEN 'ALTER PROCEDURE'
        WHEN 'a' THEN 'ALTER AGGREGATE' ELSE 'ALTER FUNCTION' END;
      EXECUTE format('%s %I.%I(%s) OWNER TO %I', statement, 'public',
        candidate.proname, pg_get_function_identity_arguments(candidate.oid), inputs.owner_name);
    END LOOP;
  END;
  $$;
  \ir setup_database_finish.sql
\else
  \echo 'Preview only. Review the owners listed above, then rerun transfer-legacy-db --apply.'
\endif
