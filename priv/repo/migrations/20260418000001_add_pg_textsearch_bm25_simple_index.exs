defmodule Zaq.Repo.Migrations.AddPgTextsearchBm25SimpleIndex do
  use Ecto.Migration

  @doc """
  Creates a BM25 index only when operator-provisioned pg_search and chunks exist.
  Native PostgreSQL remains supported without pg_search. A previous migration
  drops chunks; in that case runtime embedding setup will create the indexes.
  Unexpected index/permission errors must fail rather than silently succeeding.
  """
  def up do
    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_extension WHERE extname = 'pg_search') THEN
        RAISE NOTICE 'pg_search absent: keeping native full-text search. For fresh databases use scripts/setup_paradedb_extensions.sql before migrations (PostgreSQL: scripts/setup_postgres_extensions.sql). This database now has schema_migrations, so adding ParadeDB requires manual DBA provisioning.';
      ELSIF to_regclass('public.chunks') IS NOT NULL THEN
        CREATE INDEX IF NOT EXISTS chunks_bm25_idx
          ON public.chunks USING bm25(id, content)
          WITH (key_field='id');
        DROP INDEX IF EXISTS public.chunks_content_tsvector_idx;
      END IF;
    END;
    $$
    """)
  end

  def down do
    execute("""
    DO $$
    BEGIN
      DROP INDEX IF EXISTS public.chunks_bm25_idx;
      IF to_regclass('public.chunks') IS NOT NULL THEN
        CREATE INDEX IF NOT EXISTS chunks_content_tsvector_idx
          ON public.chunks USING gin (to_tsvector('english', content));
      END IF;
      -- Extensions are DBA-managed and must survive application rollback.
    END;
    $$
    """)
  end
end
