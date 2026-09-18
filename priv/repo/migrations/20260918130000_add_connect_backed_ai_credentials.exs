defmodule Zaq.Repo.Migrations.AddConnectBackedAiCredentials do
  use Ecto.Migration

  def up do
    alter table(:ai_provider_credentials) do
      add :connect_credential_id,
          references(:connect_credentials, on_delete: :restrict),
          null: true
    end

    create unique_index(:ai_provider_credentials, [:connect_credential_id],
             name: :ai_provider_credentials_connect_credential_index,
             where: "connect_credential_id IS NOT NULL"
           )

    create constraint(:connect_credentials, :connect_credentials_no_auth_check,
             check: """
             auth_kind <> 'none' OR (
               personal_credential_policy = 'disabled' AND
               secret_binding = 'configuration' AND
               api_key IS NULL AND client_id IS NULL AND client_secret IS NULL AND
               private_key IS NULL
             )
             """
           )

    create constraint(:connect_grants, :connect_grants_no_auth_check,
             check: "auth_kind <> 'none'"
           )
  end

  def down do
    drop constraint(:connect_grants, :connect_grants_no_auth_check)
    drop constraint(:connect_credentials, :connect_credentials_no_auth_check)

    drop index(:ai_provider_credentials, [:connect_credential_id],
           name: :ai_provider_credentials_connect_credential_index
         )

    alter table(:ai_provider_credentials) do
      remove :connect_credential_id
    end
  end
end
