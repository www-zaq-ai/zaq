defmodule Zaq.Repo.Migrations.AddSharedRoleIdsToIngestJobs do
  use Ecto.Migration

  def change do
    alter table(:ingest_jobs) do
      add :shared_role_ids, {:array, :integer}, default: []
    end
  end
end
