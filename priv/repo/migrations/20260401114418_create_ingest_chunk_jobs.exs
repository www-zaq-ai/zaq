defmodule Zaq.Repo.Migrations.CreateIngestChunkJobs do
  use Ecto.Migration

  def change do
    create table(:ingest_chunk_jobs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :ingest_job_id,
          references(:ingest_jobs, type: :binary_id, on_delete: :delete_all),
          null: false

      add :document_id, references(:documents, type: :bigint, on_delete: :delete_all), null: false
      add :chunk_index, :integer, null: false
      add :chunk_payload, :map, null: false
      add :status, :string, null: false, default: "pending"
      add :attempts, :integer, null: false, default: 0
      add :error, :text

      timestamps(type: :utc_datetime_usec)
    end

    create index(:ingest_chunk_jobs, [:ingest_job_id])
    create index(:ingest_chunk_jobs, [:status])
    create unique_index(:ingest_chunk_jobs, [:ingest_job_id, :chunk_index])
  end
end
