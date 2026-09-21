-- Shared ParadeDB installation and functional capability validation.
CREATE EXTENSION IF NOT EXISTS pg_search;

DO $$
BEGIN
  PERFORM 1 FROM paradedb.version_info();
END;
$$;
