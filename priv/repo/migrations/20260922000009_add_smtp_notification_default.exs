defmodule Zaq.Repo.Migrations.AddSmtpNotificationDefault do
  use Ecto.Migration

  def change do
    alter table(:channel_configs) do
      add :notification_default, :boolean, null: false, default: false
    end

    create unique_index(:channel_configs, [:provider],
             where:
               "provider = 'email:smtp' AND notification_default = true AND archived_at IS NULL",
             name: :channel_configs_active_smtp_notification_default_idx
           )
  end
end
