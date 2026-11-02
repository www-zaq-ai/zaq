defmodule Zaq.Repo.Migrations.AddPreparationProgressToIngestJobs do
  use Ecto.Migration

  def change do
    alter table(:ingest_jobs) do
      add :preparation_progress, :map
    end
  end
end
