defmodule Zaq.Repo.ExtensionChecks do
  @moduledoc """
  Read-only database extension prerequisites shared by migrations and runtime DDL.

  Extensions belong to the operator, not ZAQ. Checks never install, upgrade or
  remove them. Vector compatibility is checked by its visible, extension-owned
  `halfvec` capability rather than assuming a particular version string format.
  """

  alias Ecto.Adapters.SQL

  @doc "Verifies a required extension, raising an actionable database error if unavailable."
  @spec require!(module(), :vector | :pg_search) :: :ok
  def require!(repo, extension) do
    SQL.query!(repo, sql(extension), [])
    :ok
  end

  @doc "Returns prerequisite SQL suitable for Ecto migration execution."
  @spec sql(:vector | :pg_search) :: String.t()
  def sql(:vector) do
    """
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_extension e
        JOIN pg_catalog.pg_depend d ON d.refobjid = e.oid
          AND d.refclassid = 'pg_catalog.pg_extension'::regclass
          AND d.classid = 'pg_catalog.pg_type'::regclass AND d.deptype = 'e'
        WHERE e.extname = 'vector' AND d.objid = pg_catalog.to_regtype('halfvec')
      ) THEN
        RAISE EXCEPTION 'ZAQ requires vector >= 0.7.0 with halfvec visible on search_path'
          USING HINT = 'Before any migration, a DBA must bootstrap this database using scripts/setup_postgres_extensions.sql (PostgreSQL) or scripts/setup_paradedb_extensions.sql (ParadeDB). If schema_migrations already exists, bootstrap refuses: ask a DBA to provision or repair extensions manually in this same database, then retry. Older extensions require a DBA-managed upgrade; also check search_path.';
      END IF;
    END;
    $$
    """
  end

  def sql(:pg_search) do
    """
    DO $$
    BEGIN
      IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_extension WHERE extname = 'pg_search') THEN
        RAISE EXCEPTION 'ZAQ ParadeDB backend requires the pg_search extension'
          USING HINT = 'Before any migration, a DBA must bootstrap this database using scripts/setup_paradedb_extensions.sql. If schema_migrations already exists, ask a DBA to provision pg_search manually in this same database, then retry. Plain PostgreSQL uses native full-text search and scripts/setup_postgres_extensions.sql instead.';
      END IF;
    END;
    $$
    """
  end
end
