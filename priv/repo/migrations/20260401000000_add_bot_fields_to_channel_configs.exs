defmodule Zaq.Repo.Migrations.AddBotFieldsToChannelConfigs do
  use Ecto.Migration

  def change do
    alter table(:channel_configs) do
      add :bot_name, :string
      add :bot_user_id, :string
    end
  end
end
