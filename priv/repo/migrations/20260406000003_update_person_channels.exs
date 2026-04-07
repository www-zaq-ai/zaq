defmodule Zaq.Repo.Migrations.UpdatePersonChannels do
  use Ecto.Migration

  def up do
    alter table(:channels) do
      add :username, :string
      add :display_name, :string
      add :phone, :string
      add :last_interaction_at, :utc_datetime
      add :dm_channel_id, :string
    end

    drop_if_exists unique_index(:channels, [:person_id, :platform])
    create unique_index(:channels, [:person_id, :platform, :channel_identifier])
  end

  def down do
    drop_if_exists unique_index(:channels, [:person_id, :platform, :channel_identifier])
    create unique_index(:channels, [:person_id, :platform])

    alter table(:channels) do
      remove :username
      remove :display_name
      remove :phone
      remove :last_interaction_at
      remove :dm_channel_id
    end
  end
end
