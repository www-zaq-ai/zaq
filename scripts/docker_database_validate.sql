-- Restart validation is read-only. Never run bootstrap or repair ACLs here.
\if :{?zaq_already_connected}
\else
  SELECT 'dbname=' || chr(39) || replace(replace(:'zaq_database', chr(92), chr(92) || chr(92)), chr(39), chr(92) || chr(39)) || chr(39) AS target \gset
  \connect -reuse-previous=on :"target"
\endif
SELECT set_config('zaq.bootstrap_owner', :'zaq_owner', false) AS owner_setting,
       set_config('zaq.bootstrap_reader', :'zaq_reader', false) AS reader_setting,
       set_config('zaq.bootstrap_engine', :'zaq_bootstrap_engine', false) AS engine_setting \gset
DO $$
DECLARE
  owner_name text := current_setting('zaq.bootstrap_owner');
  reader_name text := current_setting('zaq.bootstrap_reader');
BEGIN
  IF (SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = current_database()) <> owner_name
    OR (SELECT count(*) FROM pg_roles WHERE rolname IN (owner_name, reader_name)
      AND rolcanlogin AND NOT rolsuper AND NOT rolcreatedb
      AND rolcreaterole = (rolname = owner_name)
      AND NOT rolreplication AND NOT rolbypassrls) <> 2
    OR EXISTS (
      SELECT 1 FROM pg_auth_members m
      JOIN pg_roles r ON r.oid IN (m.roleid, m.member)
      JOIN pg_roles granted_role ON granted_role.oid = m.roleid
      WHERE r.rolname IN (owner_name, reader_name)
        -- PostgreSQL grants creators ADMIN without inheritance or SET ROLE access.
        AND NOT (r.rolname = owner_name AND m.member = r.oid
          AND granted_role.rolname NOT IN (owner_name, reader_name)
          AND m.admin_option AND NOT m.inherit_option AND NOT m.set_option
          AND NOT granted_role.rolsuper AND NOT granted_role.rolcreatedb
          AND NOT granted_role.rolcreaterole AND NOT granted_role.rolreplication
          AND NOT granted_role.rolbypassrls)) THEN
    RAISE EXCEPTION 'Provisioned database owner/roles changed; explicit DBA maintenance required';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_extension e JOIN pg_depend d ON d.refobjid = e.oid
      AND d.refclassid = 'pg_extension'::regclass AND d.classid = 'pg_type'::regclass
      AND d.deptype = 'e'
    WHERE e.extname = 'vector' AND d.objid = to_regtype('public.halfvec')
      AND e.extowner = (SELECT oid FROM pg_roles WHERE rolname = current_user)
  ) THEN
    RAISE EXCEPTION 'Provisioned vector capability changed; explicit DBA maintenance required';
  END IF;
  IF current_setting('zaq.bootstrap_engine') = 'paradedb' THEN
    IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_search'
      AND extowner = (SELECT oid FROM pg_roles WHERE rolname = current_user)) THEN
      RAISE EXCEPTION 'Provisioned pg_search extension changed';
    END IF;
    PERFORM 1 FROM paradedb.version_info();
  END IF;
END;
$$;
