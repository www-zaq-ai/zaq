-- Restart validation is read-only. Never run bootstrap or repair ACLs here.
SELECT 'dbname=' || chr(39) || replace(replace(:'zaq_database', chr(92), chr(92) || chr(92)), chr(39), chr(92) || chr(39)) || chr(39) AS target \gset
\connect -reuse-previous=on :"target"
SELECT set_config('zaq.bootstrap_owner', :'zaq_owner', false) AS owner_setting,
       set_config('zaq.bootstrap_reader', :'zaq_reader', false) AS reader_setting \gset
DO $$
DECLARE
  owner_name text := current_setting('zaq.bootstrap_owner');
  reader_name text := current_setting('zaq.bootstrap_reader');
BEGIN
  IF (SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = current_database()) <> owner_name
    OR (SELECT count(*) FROM pg_roles WHERE rolname IN (owner_name, reader_name)
      AND rolcanlogin AND NOT rolsuper AND NOT rolcreatedb AND NOT rolcreaterole
      AND NOT rolreplication AND NOT rolbypassrls) <> 2
    OR EXISTS (SELECT 1 FROM pg_auth_members m JOIN pg_roles r ON r.oid IN (m.roleid, m.member)
      WHERE r.rolname IN (owner_name, reader_name)) THEN
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
  IF (SELECT engine FROM zaq_bootstrap.receipt) = 'paradedb' THEN
    IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_search'
      AND extowner = (SELECT oid FROM pg_roles WHERE rolname = current_user)) THEN
      RAISE EXCEPTION 'Provisioned pg_search extension changed';
    END IF;
    PERFORM 1 FROM paradedb.version_info();
  END IF;
END;
$$;
