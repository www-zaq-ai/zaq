defmodule Zaq.Repo.Migrations.AddTitleToChunks do
  use Ecto.Migration

  @moduledoc """
  Adds a nullable `title` column to `chunks` for existing installs.

  The chunks table is created at runtime in `Zaq.Ingestion.Chunk.create_table/1`
  (dynamic embedding dimension), so fresh installs get `title` from there. This
  migration covers databases whose chunks table predates the column.

  The descriptive, LLM-generated chunk title is stored here instead of
  overwriting the chunk's `content`/`section_path`, so the original document
  headings stay intact and searchable. Nullable: existing rows keep `NULL`
  until the document is re-ingested.
  """

  def up do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'public' AND table_name = 'chunks'
      ) THEN
        ALTER TABLE chunks ADD COLUMN IF NOT EXISTS title text;
      END IF;
    END;
    $$
    """)
  end

  def down do
    execute("ALTER TABLE chunks DROP COLUMN IF EXISTS title")
  end
end
