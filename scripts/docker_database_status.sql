-- Connect safely using a conninfo-quoted target (same contract as DBA bootstrap).
SELECT 'dbname=' || chr(39) || replace(replace(:'zaq_database', chr(92), chr(92) || chr(92)), chr(39), chr(92) || chr(39)) || chr(39) AS target \gset
\connect -reuse-previous=on :"target"
SELECT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'zaq_bootstrap') AS has_receipt \gset
\if :has_receipt
  -- Reject even a lookalike schema/table created by the application owner.
  SELECT EXISTS (
    SELECT 1 FROM pg_namespace n JOIN pg_class c ON c.relnamespace = n.oid
    JOIN pg_roles r ON r.oid = n.nspowner AND r.oid = c.relowner
    WHERE n.nspname = 'zaq_bootstrap' AND c.relname = 'receipt'
      AND c.relkind = 'r' AND r.rolname = current_user AND r.rolsuper
  ) AS trusted \gset
  \if :trusted
    SELECT CASE WHEN count(*) = 1 AND bool_and(
      version = 1
      AND database_name = current_database() AND owner_name = :'zaq_owner'
      AND reader_name = :'zaq_reader' AND engine = :'zaq_bootstrap_engine'
    ) THEN true ELSE false END AS zaq_provisioned FROM zaq_bootstrap.receipt \gset
    \if :zaq_provisioned
    \else
      DO $$ BEGIN RAISE EXCEPTION 'Database bootstrap receipt does not match requested identity/engine'; END $$;
    \endif
  \else
    DO $$ BEGIN RAISE EXCEPTION 'Untrusted database bootstrap receipt'; END $$;
  \endif
\else
  \set zaq_provisioned false
\endif
