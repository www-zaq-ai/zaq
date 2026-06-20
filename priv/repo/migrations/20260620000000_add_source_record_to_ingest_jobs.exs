defmodule Zaq.Repo.Migrations.AddSourceRecordToIngestJobs do
  use Ecto.Migration

  def change do
    alter table(:ingest_jobs) do
      add :source_record, :map
    end
  end
end
