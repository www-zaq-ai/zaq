defmodule Zaq.Repo.Migrations.CreateNotificationLogs do
  use Ecto.Migration

  def change do
    create table(:notification_logs) do
      add :sender, :string, null: false
      add :recipient_name, :string
      add :recipient_ref_type, :string
      add :recipient_ref_id, :integer
      add :payload, :map, null: false
      add :channels_tried, :map, null: false, default: "[]"
      add :status, :string, null: false, default: "pending"

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:notification_logs, [:status])
    create index(:notification_logs, [:inserted_at])
    create index(:notification_logs, [:recipient_ref_type, :recipient_ref_id])
    create index(:notification_logs, [:sender])
  end
end
