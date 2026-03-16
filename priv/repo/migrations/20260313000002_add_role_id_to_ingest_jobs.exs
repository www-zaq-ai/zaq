defmodule Zaq.Repo.Migrations.AddRoleIdToIngestJobs do
  use Ecto.Migration

  def change do
    alter table(:ingest_jobs) do
      add :role_id, references(:roles, on_delete: :nilify_all), null: true
    end

    create index(:ingest_jobs, [:role_id])
  end
end
