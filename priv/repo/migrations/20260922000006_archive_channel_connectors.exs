defmodule Zaq.Repo.Migrations.ArchiveChannelConnectors do
  use Ecto.Migration

  def change do
    alter table(:channel_configs) do
      add :archived_at, :utc_datetime
    end

    create index(:channel_configs, [:provider],
             where: "archived_at IS NULL",
             name: :channel_configs_live_provider_index
           )
  end
end
