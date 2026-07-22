defmodule Zaq.Repo.Migrations.CreateDataSourceWatchChannels do
  use Ecto.Migration

  def change do
    create table(:data_source_watch_channels) do
      add :config_id, references(:channel_configs, on_delete: :delete_all), null: false
      add :provider, :string, null: false
      add :target_source, :text, null: false
      add :target_provider_id, :string, null: false
      add :target_kind, :string, null: false
      add :channel_id, :string, null: false
      add :resource_id, :string
      add :resource_uri, :text
      add :checkpoint, :text
      add :expiration_at, :utc_datetime
      add :status, :string, null: false, default: "active"
      add :last_error, :text
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create unique_index(:data_source_watch_channels, [:provider, :channel_id])
    create index(:data_source_watch_channels, [:provider, :channel_id, :resource_id])
    create index(:data_source_watch_channels, [:config_id, :target_source])
  end
end
