-- Read-only preflight. Reuse the normal role/extension validator before this file.
-- Run under the same transaction and advisory lock that will create the receipt.
DO $$
DECLARE
  owner_name text := current_setting('zaq.bootstrap_owner');
  reader_name text := current_setting('zaq.bootstrap_reader');
  creator_oid oid;
  invalid_object text;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relname = 'schema_migrations' AND n.nspname NOT LIKE 'pg_temp_%'
  ) THEN
    RAISE EXCEPTION 'Adoption requires an already migrated database (schema_migrations missing)';
  END IF;
  IF (SELECT count(*) FROM pg_roles WHERE rolname IN (owner_name, reader_name)
       AND NOT rolinherit AND (rolvaliduntil IS NULL OR rolvaliduntil = 'infinity'::timestamptz)) <> 2 THEN
    RAISE EXCEPTION 'Owner and reader must be non-inheriting logins without expiry';
  END IF;
  IF EXISTS (
    SELECT 1 FROM pg_shdepend d JOIN pg_roles r ON r.oid = d.refobjid
    WHERE r.rolname IN (owner_name, reader_name) AND d.refclassid = 'pg_authid'::regclass
      AND d.dbid <> 0 AND d.dbid <> (SELECT oid FROM pg_database WHERE datname = current_database())
  ) OR EXISTS (
    SELECT 1 FROM pg_shdepend d JOIN pg_roles r ON r.oid = d.refobjid
    WHERE r.rolname = reader_name AND d.refclassid = 'pg_authid'::regclass AND d.deptype = 'o'
  ) OR EXISTS (
    SELECT 1 FROM pg_database d JOIN pg_roles r ON r.oid = d.datdba
    WHERE r.rolname IN (owner_name, reader_name) AND d.datname <> current_database()
  ) THEN
    RAISE EXCEPTION 'Owner/reader roles are shared with another database or reader owns objects';
  END IF;
  IF NOT has_database_privilege(reader_name, current_database(), 'CONNECT')
    OR has_database_privilege(reader_name, current_database(), 'CREATE')
    OR has_database_privilege(reader_name, current_database(), 'TEMPORARY')
    OR EXISTS (
      SELECT 1 FROM aclexplode(coalesce((SELECT datacl FROM pg_database WHERE datname = current_database()),
        acldefault('d', (SELECT datdba FROM pg_database WHERE datname = current_database())))) acl
      WHERE acl.grantee = 0 AND acl.privilege_type IN ('CREATE', 'TEMPORARY')
    ) THEN
    RAISE EXCEPTION 'Reader or PUBLIC has unsafe database privileges';
  END IF;
  IF to_regnamespace('zaq_bootstrap') IS NOT NULL
    AND has_schema_privilege(reader_name, 'zaq_bootstrap', 'USAGE') THEN
    RAISE EXCEPTION 'Reader may not access the bootstrap receipt schema';
  END IF;
  SELECT n.nspname INTO invalid_object FROM pg_namespace n
    WHERE n.nspname NOT IN ('information_schema', 'zaq_bootstrap') AND n.nspname !~ '^pg_'
      AND (NOT has_schema_privilege(reader_name, n.oid, 'USAGE')
        OR has_schema_privilege(reader_name, n.oid, 'CREATE'))
    LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION 'Reader schema privileges differ from bootstrap policy: %', invalid_object;
  END IF;
  SELECT format('%I.%I', n.nspname, c.relname) INTO invalid_object
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname NOT IN ('information_schema', 'zaq_bootstrap') AND n.nspname !~ '^pg_'
      AND c.relkind IN ('r', 'p', 'v', 'm', 'f')
      AND (NOT has_table_privilege(reader_name, c.oid, 'SELECT')
        OR has_table_privilege(reader_name, c.oid, 'INSERT')
        OR has_table_privilege(reader_name, c.oid, 'UPDATE')
        OR has_table_privilege(reader_name, c.oid, 'DELETE')
        OR has_table_privilege(reader_name, c.oid, 'TRUNCATE')
        OR has_table_privilege(reader_name, c.oid, 'REFERENCES')
        OR has_table_privilege(reader_name, c.oid, 'TRIGGER'))
    LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION 'Reader table privileges differ from bootstrap policy: %', invalid_object;
  END IF;
  SELECT format('%I.%I', n.nspname, c.relname) INTO invalid_object
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname NOT IN ('information_schema', 'zaq_bootstrap') AND n.nspname !~ '^pg_'
      AND c.relkind = 'S' AND (NOT has_sequence_privilege(reader_name, c.oid, 'SELECT')
        OR has_sequence_privilege(reader_name, c.oid, 'USAGE')
        OR has_sequence_privilege(reader_name, c.oid, 'UPDATE'))
    LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION 'Reader sequence privileges differ from bootstrap policy: %', invalid_object;
  END IF;
  IF EXISTS (
    SELECT 1 FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE a.attnum > 0 AND NOT a.attisdropped
      AND n.nspname NOT IN ('information_schema', 'zaq_bootstrap') AND n.nspname !~ '^pg_'
      AND c.relkind IN ('r', 'p', 'v', 'm', 'f')
      AND (has_column_privilege(reader_name, c.oid, a.attnum, 'INSERT')
        OR has_column_privilege(reader_name, c.oid, a.attnum, 'UPDATE')
        OR has_column_privilege(reader_name, c.oid, a.attnum, 'REFERENCES'))
  ) OR EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname NOT IN ('information_schema', 'zaq_bootstrap') AND n.nspname !~ '^pg_'
      AND has_function_privilege(reader_name, p.oid, 'EXECUTE')
  ) THEN
    RAISE EXCEPTION 'Reader has column-write or routine-execution privileges';
  END IF;
  -- Global defaults must cover future schemas and objects for both creators.
  FOREACH creator_oid IN ARRAY ARRAY[
    (SELECT oid FROM pg_roles WHERE rolname = owner_name),
    (SELECT oid FROM pg_roles WHERE rolname = current_user)
  ] LOOP
    IF NOT EXISTS (
      SELECT 1 FROM pg_default_acl d WHERE d.defaclrole = creator_oid
        AND d.defaclnamespace = 0 AND d.defaclobjtype = 'f'
    ) THEN
      RAISE EXCEPTION 'Function default privileges are not restricted for creator %', creator_oid::regrole;
    END IF;
    IF EXISTS (
      SELECT 1 FROM (VALUES ('n'::char, 'USAGE'), ('r'::char, 'SELECT'),
                          ('S'::char, 'SELECT')) required(objtype, privilege)
      WHERE NOT EXISTS (
        SELECT 1 FROM pg_default_acl d CROSS JOIN LATERAL aclexplode(d.defaclacl) acl
        WHERE d.defaclrole = creator_oid AND d.defaclnamespace = 0
          AND d.defaclobjtype = required.objtype
          AND acl.grantee = (SELECT oid FROM pg_roles WHERE rolname = reader_name)
          AND acl.privilege_type = required.privilege
      )
    ) THEN
      RAISE EXCEPTION 'Reader default privileges are missing for creator %', creator_oid::regrole;
    END IF;
  END LOOP;
  IF EXISTS (
    SELECT 1 FROM pg_default_acl d CROSS JOIN LATERAL aclexplode(d.defaclacl) acl
    WHERE d.defaclrole IN ((SELECT oid FROM pg_roles WHERE rolname = owner_name),
                           (SELECT oid FROM pg_roles WHERE rolname = current_user))
      AND (acl.grantee = 0 OR acl.grantee = (SELECT oid FROM pg_roles WHERE rolname = reader_name))
      AND ((d.defaclobjtype IN ('r', 'S') AND acl.privilege_type <> 'SELECT')
        OR (d.defaclobjtype = 'n' AND acl.privilege_type = 'CREATE')
        OR (d.defaclobjtype = 'f' AND acl.privilege_type = 'EXECUTE'))
  ) THEN
    RAISE EXCEPTION 'Unsafe PUBLIC or reader default privileges';
  END IF;
END;
$$;
