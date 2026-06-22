defmodule Zaq.Repo.Migrations.EnsurePgSearchCurrent do
  use Ecto.Migration

  @moduledoc """
  Deterministically ensures the `pg_search` extension is created and up to date
  in every environment that has it available (ParadeDB servers), and is a clean
  no-op on standard Postgres (CI, dev without ParadeDB).

  Extensions are per-database and version-managed, so the robust place to
  provision them is the migration flow — it runs uniformly across dev, test, CI
  and prod, including the separate test database. This is what makes the fix
  reliable rather than dependent on app-boot side effects; the runtime
  `Zaq.Ingestion.FTSBackend.self_heal/0` remains only a safety net for
  already-running deployments. See docs/exec-plans/issues/paraddb.md.

  Behaviour:

    * Guarded on `pg_available_extensions`, so `CREATE`/`ALTER` only run where the
      pg_search library is actually present. On standard Postgres this is a
      no-op and never errors.
    * `ALTER EXTENSION pg_search UPDATE` fixes databases whose extension is older
      than a later-loaded library (e.g. after a ParadeDB image upgrade) — the
      case that breaks `paradedb.version_info()` and `pg_dump`.
    * If pg_search is present but cannot be enabled (it is not loaded via
      `shared_preload_libraries`), the migration does not fail the deploy: it
      raises a visible WARNING and lets ZAQ run degraded. This is a server config
      the migration cannot fix; `FTSBackend.warn_if_degraded/2` surfaces it again
      at startup.
  """
  def up do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_search') THEN
        BEGIN
          CREATE EXTENSION IF NOT EXISTS pg_search;
          ALTER EXTENSION pg_search UPDATE;
        EXCEPTION WHEN OTHERS THEN
          RAISE WARNING 'pg_search is available but could not be enabled (is it in shared_preload_libraries?): %', SQLERRM;
        END;
      END IF;
    END
    $$;
    """)
  end

  def down do
    # Intentionally a no-op: dropping pg_search would cascade-drop the BM25 index
    # and break search on rollback. Leave the extension in place.
    :ok
  end
end
