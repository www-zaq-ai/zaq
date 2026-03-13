defmodule Zaq.Repo.Migrations.AddVolumeNameToIngestJobs do
  use Ecto.Migration

  def change do
    alter table(:ingest_jobs) do
      add :volume_name, :string
    end
  end
end
