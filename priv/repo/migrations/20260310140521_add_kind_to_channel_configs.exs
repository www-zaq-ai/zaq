defmodule Zaq.Repo.Migrations.AddKindToChannelConfigs do
  use Ecto.Migration

  def up do
    alter table(:channel_configs) do
      add :kind, :string, null: false, default: "retrieval"
    end

    create index(:channel_configs, [:kind])
  end

  def down do
    drop index(:channel_configs, [:kind])

    alter table(:channel_configs) do
      remove :kind
    end
  end
end
