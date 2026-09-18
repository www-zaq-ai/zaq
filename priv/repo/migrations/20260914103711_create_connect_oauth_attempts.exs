defmodule Zaq.Repo.Migrations.CreateConnectOauthAttempts do
  use Ecto.Migration

  def change do
    create table(:connect_oauth_attempts, primary_key: false) do
      add :id, :text, primary_key: true
      add :credential_id, references(:connect_credentials, on_delete: :delete_all)
      add :owner_type, :text, null: false
      add :owner_id, :bigint
      add :provider, :text, null: false
      add :config_fingerprint, :binary, null: false
      add :redirect_uri, :text, null: false
      add :pkce_verifier, :text
      add :candidate_config, :text
      add :expires_at, :utc_datetime_usec, null: false
      add :claimed_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:connect_oauth_attempts, [:expires_at, :id])
    create index(:connect_oauth_attempts, [:credential_id])

    create constraint(:connect_oauth_attempts, :connect_oauth_attempt_owner_check,
             check:
               "(owner_type = 'org' AND owner_id IS NULL) OR (owner_type = 'person' AND owner_id IS NOT NULL AND owner_id > 0 AND credential_id IS NOT NULL AND candidate_config IS NULL)"
           )
  end
end
