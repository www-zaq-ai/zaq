defmodule Zaq.Repo.Migrations.CreateChunks do
  use Ecto.Migration

  def up do
    execute "CREATE EXTENSION IF NOT EXISTS vector"

    # Read dimension from config, default to 3584
    dimension =
      Application.get_env(:zaq, Zaq.Embedding.Client, [])
      |> Keyword.get(:dimension, 3584)

    create table(:chunks) do
      add :document_id, references(:documents, on_delete: :delete_all), null: false
      add :content, :text, null: false
      add :chunk_index, :integer, null: false
      add :section_path, {:array, :string}, default: []
      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime)
    end

    # Add halfvec column with configured dimension
    execute "ALTER TABLE chunks ADD COLUMN embedding halfvec(#{dimension})"

    # HNSW index for vector similarity search
    execute """
    CREATE INDEX chunks_embedding_idx
    ON chunks
    USING hnsw (embedding halfvec_l2_ops)
    WITH (m = 16, ef_construction = 64)
    """

    # B-tree index on document_id for fast joins
    create index(:chunks, [:document_id])

    # GIN index for full-text search
    execute """
    CREATE INDEX chunks_content_tsvector_idx
    ON chunks
    USING gin (to_tsvector('english', content))
    """
  end

  def down do
    drop table(:chunks)
    # Extension is shared, don't drop it
  end
end
