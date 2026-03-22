defmodule Zaq.Repo.Migrations.CreateUserNotificationChannels do
  use Ecto.Migration

  def change do
    create table(:user_notification_channels) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :platform, :string, null: false
      add :identifier, :string, null: false
      add :is_preferred, :boolean, null: false, default: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:user_notification_channels, [:user_id, :platform])
    create index(:user_notification_channels, [:user_id])
  end
end
