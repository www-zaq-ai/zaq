defmodule Zaq.Repo.Migrations.AddDocumentIdIndexToIngestChunkJobs do
  use Ecto.Migration

  def change do
    create index(:ingest_chunk_jobs, [:document_id])
  end
end
