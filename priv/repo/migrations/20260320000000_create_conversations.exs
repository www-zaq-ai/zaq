defmodule Zaq.Repo.Migrations.CreateConversations do
  use Ecto.Migration

  def change do
    create table(:conversations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :title, :string
      add :user_id, references(:users, on_delete: :nilify_all), null: true
      add :channel_user_id, :string
      add :channel_type, :string, null: false
      add :channel_config_id, references(:channel_configs, on_delete: :nilify_all), null: true
      add :status, :string, default: "active", null: false
      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:conversations, [:user_id])
    create index(:conversations, [:channel_user_id, :channel_type])
    create index(:conversations, [:channel_config_id])
    create index(:conversations, [:status])
  end
end
