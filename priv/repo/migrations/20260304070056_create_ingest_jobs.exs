defmodule Zaq.Repo.Migrations.CreateIngestJobs do
  use Ecto.Migration

  def change do
    create table(:ingest_jobs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :file_path, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :error, :text
      add :mode, :string, null: false, default: "async"
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      add :chunks_count, :integer, default: 0
      add :document_id, references(:documents, type: :bigint, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create index(:ingest_jobs, [:status])
    create index(:ingest_jobs, [:document_id])
  end
end
