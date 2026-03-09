defmodule Zaq.Repo.Migrations.CreateChannelConfigs do
  use Ecto.Migration

  def change do
    create table(:channel_configs) do
      add :name, :string, null: false
      add :provider, :string, null: false
      add :url, :string, null: false
      add :token, :string, null: false
      add :enabled, :boolean, default: true, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:channel_configs, [:provider])
  end
end
