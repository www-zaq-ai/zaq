-- Shared vector installation and capability validation.
CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA public;

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
      USING HINT = 'Upgrade the package/extension or reconcile its schema; setup never upgrades or relocates extensions.';
  END IF;
END;
$$;
