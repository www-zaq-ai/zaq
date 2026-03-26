defmodule Zaq.Repo.Migrations.ResetIngestion do
  use Ecto.Migration

  import Ecto.Query

  alias Zaq.Ingestion.{FileExplorer, SourcePath}

  def up do
    delete_sidecar_files()
    drop table(:chunks)
    execute "UPDATE documents SET content = NULL"
  end

  def down do
    execute "CREATE EXTENSION IF NOT EXISTS vector"

    dimension =
      Application.get_env(:zaq, Zaq.Embedding.Client, [])
      |> Keyword.get(:dimension, 3584)

    create table(:chunks) do
      add :document_id, references(:documents, on_delete: :delete_all), null: false
      add :content, :text, null: false
      add :chunk_index, :integer, null: false
      add :section_path, {:array, :string}, default: []
      add :metadata, :map, default: %{}
      add :role_id, references(:roles, on_delete: :nilify_all)
      add :shared_role_ids, {:array, :integer}, default: []

      timestamps(type: :utc_datetime)
    end

    execute "ALTER TABLE chunks ADD COLUMN embedding halfvec(#{dimension})"

    execute """
    CREATE INDEX chunks_embedding_idx
    ON chunks
    USING hnsw (embedding halfvec_l2_ops)
    WITH (m = 16, ef_construction = 64)
    """

    create index(:chunks, [:document_id])

    execute """
    CREATE INDEX chunks_content_tsvector_idx
    ON chunks
    USING gin (to_tsvector('english', content))
    """
  end

  defp delete_sidecar_files do
    volumes = FileExplorer.list_volumes()

    {:ok, %{rows: rows}} =
      Ecto.Adapters.SQL.query(
        repo(),
        "SELECT source FROM documents WHERE metadata->>'source_document_source' IS NOT NULL",
        []
      )

    Enum.each(rows, fn [source] ->
      {volume, relative} = SourcePath.split_source(source, nil, volumes)

      case FileExplorer.resolve_path(volume, relative) do
        {:ok, abs_path} ->
          File.rm(abs_path)

        _ ->
          :skip
      end
    end)
  end
end
