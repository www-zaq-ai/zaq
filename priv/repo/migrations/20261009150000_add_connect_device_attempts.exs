defmodule Zaq.Repo.Migrations.AddConnectDeviceAttempts do
  use Ecto.Migration

  def change do
    create table(:connect_device_attempts, primary_key: false) do
      add :id, :string, primary_key: true
      add :credential_id, references(:connect_credentials, on_delete: :delete_all)
      add :owner_type, :string, null: false
      add :owner_id, :bigint
      add :session_id, references(:person_sessions, type: :binary_id, on_delete: :delete_all)
      add :provider, :string, null: false
      add :config_fingerprint, :binary, null: false
      add :candidate_config, :text
      add :device_material, :text
      add :worker_pid, :binary
      add :verification_uri, :text
      add :user_code, :text
      add :interval, :integer
      add :expires_at, :utc_datetime_usec, null: false
      add :status, :string, null: false, default: "pending"
      add :result_credential_id, references(:connect_credentials, on_delete: :delete_all)
      timestamps(type: :utc_datetime_usec)
    end

    create index(:connect_device_attempts, [:expires_at, :id])
    create index(:connect_device_attempts, [:owner_type, :owner_id])

    create constraint(:connect_device_attempts, :connect_device_attempt_owner_check,
             check:
               "(owner_type = 'org' AND owner_id IS NULL AND session_id IS NULL) OR (owner_type = 'person' AND owner_id > 0 AND session_id IS NOT NULL)"
           )

    create constraint(:connect_device_attempts, :connect_device_attempt_status_check,
             check:
               "status IN ('pending', 'active', 'cancelled', 'expired', 'denied', 'failed', 'interrupted')"
           )
  end
end
