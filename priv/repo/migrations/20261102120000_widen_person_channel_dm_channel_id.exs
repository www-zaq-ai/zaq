defmodule Zaq.Repo.Migrations.WidenPersonChannelDmChannelId do
  use Ecto.Migration

  def change do
    alter table(:channels) do
      modify :dm_channel_id, :text, from: :string
    end
  end
end
