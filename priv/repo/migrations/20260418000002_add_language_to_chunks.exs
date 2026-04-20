defmodule Zaq.Repo.Migrations.AddLanguageToChunks do
  use Ecto.Migration

  @doc """
  Adds the `language` column to chunks for per-language BM25 partial indexes.

  Wrapped in a DO block so it applies cleanly even when the chunks table does
  not yet exist (it may be recreated dynamically via Chunk.create_table/1 after
  a reset_ingestion migration dropped it).
  """
  def up do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT FROM information_schema.tables
        WHERE table_schema = 'public' AND table_name = 'chunks'
      ) THEN
        ALTER TABLE chunks ADD COLUMN IF NOT EXISTS language varchar(32);
        UPDATE chunks SET language = 'simple' WHERE language IS NULL;
      END IF;
    END;
    $$
    """)
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT FROM information_schema.tables
        WHERE table_schema = 'public' AND table_name = 'chunks'
      ) THEN
        ALTER TABLE chunks DROP COLUMN IF EXISTS language;
      END IF;
    END;
    $$
    """)
  end
end
