defmodule Zaq.Repo.Migrations.AddChunkProgressToIngestJobs do
  use Ecto.Migration

  def change do
    alter table(:ingest_jobs) do
      add :total_chunks, :integer, default: 0, null: false
      add :ingested_chunks, :integer, default: 0, null: false
      add :failed_chunks, :integer, default: 0, null: false
      add :failed_chunk_indices, {:array, :integer}, default: [], null: false
    end

    execute("""
    UPDATE ingest_jobs
    SET total_chunks = COALESCE(chunks_count, 0),
        ingested_chunks = COALESCE(chunks_count, 0),
        failed_chunks = 0,
        failed_chunk_indices = '{}'
    """)
  end
end
