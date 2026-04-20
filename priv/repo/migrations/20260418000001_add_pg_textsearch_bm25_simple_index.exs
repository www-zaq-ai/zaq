defmodule Zaq.Repo.Migrations.AddPgTextsearchBm25SimpleIndex do
  use Ecto.Migration

  @doc """
  Enables pg_search (ParadeDB), drops the legacy GIN tsvector index, and creates
  a single BM25 index on chunks(content).

  Wrapped in a DO/EXCEPTION block so deployments without pg_search apply
  cleanly without breaking. The GIN index is only dropped when the extension
  is successfully created.
  """
  def up do
    execute("""
    DO $$
    BEGIN
      CREATE EXTENSION IF NOT EXISTS pg_search;
      DROP INDEX IF EXISTS chunks_content_tsvector_idx;
      CREATE INDEX IF NOT EXISTS chunks_bm25_idx
        ON chunks USING bm25(id, content)
        WITH (key_field='id');
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'pg_search setup skipped (extension unavailable): %', SQLERRM;
    END;
    $$
    """)
  end

  def down do
    execute("""
    DO $$
    BEGIN
      DROP INDEX IF EXISTS chunks_bm25_idx;
      CREATE INDEX IF NOT EXISTS chunks_content_tsvector_idx
        ON chunks USING gin (to_tsvector('english', content));
      DROP EXTENSION IF EXISTS pg_search;
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'pg_search rollback skipped: %', SQLERRM;
    END;
    $$
    """)
  end
end
