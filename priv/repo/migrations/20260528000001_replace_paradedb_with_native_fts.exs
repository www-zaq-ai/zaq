defmodule Zaq.Repo.Migrations.AddNativeFtsColumn do
  use Ecto.Migration

  @moduledoc """
  Adds the native PostgreSQL FTS column and GIN index alongside any existing
  ParadeDB BM25 index. Both indexes coexist after this migration runs.

  The active backend (ParadeDB or native FTS) is selected automatically at
  application startup by probing pg_extension — not by this migration.

  - ParadeDB deployments: chunks_bm25_idx stays intact; content_tsv is added
    as a harmless extra column used once the customer switches to native FTS.
  - Native deployments: no pg_search, no BM25 index; content_tsv + GIN are
    the only FTS structures present.

  Intentionally does NOT drop pg_search or chunks_bm25_idx.
  """

  def up do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'public' AND table_name = 'chunks'
      ) THEN
        ALTER TABLE chunks
          ADD COLUMN IF NOT EXISTS content_tsv tsvector
          GENERATED ALWAYS AS (to_tsvector('english', content)) STORED;

        CREATE INDEX IF NOT EXISTS chunks_content_tsv_idx
          ON chunks USING gin(content_tsv);
      END IF;
    END;
    $$
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS chunks_content_tsv_idx")
    execute("ALTER TABLE chunks DROP COLUMN IF EXISTS content_tsv")
  end
end
