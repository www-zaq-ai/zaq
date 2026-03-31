defmodule Zaq.Repo.Migrations.AddSmeChannelIdToChannelConfigs do
  use Ecto.Migration

  def change do
    alter table(:channel_configs) do
      add :sme_channel_id, :string
    end
  end
end
