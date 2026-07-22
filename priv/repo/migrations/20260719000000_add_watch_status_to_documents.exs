defmodule Zaq.Repo.Migrations.AddWatchStatusToDocuments do
  use Ecto.Migration

  def change do
    alter table(:documents) do
      add :watch_status, :string, null: false, default: "unwatched"
      add :watch_requested_at, :utc_datetime
      add :watch_updated_at, :utc_datetime
      add :watch_error, :text
    end

    create index(:documents, [:watch_status])
  end
end
