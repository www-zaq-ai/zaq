defmodule Zaq.Repo.Migrations.AddCanonicalConnectGrantStorage do
  use Ecto.Migration

  def up do
    alter table(:connect_credentials) do
      add :personal_credential_policy, :string, null: false, default: "disabled"
      add :secret_binding, :string, null: false, default: "configuration"
    end

    create constraint(:connect_credentials, :connect_credentials_personal_policy_check,
             check: "personal_credential_policy IN ('disabled', 'optional', 'required')"
           )

    create constraint(:connect_credentials, :connect_credentials_secret_binding_check,
             check: "secret_binding IN ('configuration', 'grant')"
           )

    create constraint(:connect_grants, :connect_grants_resource_check,
             check: """
             resource_type IS NOT NULL AND resource_id IS NOT NULL AND
             (resource_type IN ('data_source', 'mcp', 'ai_provider_credential')
              OR (resource_type = 'connect_credential' AND credential_id IS NOT NULL
                  AND resource_id = credential_id::text))
             """
           )

    create constraint(:connect_grants, :connect_grants_owner_check,
             check: """
             owner_type IS NOT NULL AND (
             (resource_type <> 'connect_credential' AND owner_type IN ('org', 'user'))
             OR (resource_type = 'connect_credential' AND (
               (owner_type = 'org' AND owner_id IS NULL)
               OR (owner_type = 'person' AND owner_id IS NOT NULL)
             )))
             """
           )

    create unique_index(:connect_grants, [:credential_id, :owner_id],
             name: :connect_grants_credential_person_index,
             where: "resource_type = 'connect_credential' AND owner_type = 'person'"
           )

    create unique_index(:connect_grants, [:credential_id],
             name: :connect_grants_credential_org_index,
             where: "resource_type = 'connect_credential' AND owner_type = 'org'"
           )
  end

  def down do
    # Hold the write lock through the guard and DDL so concurrent inserts cannot
    # turn a safe rollback into secret loss between the check and column removal.
    execute "LOCK TABLE connect_credentials, connect_grants IN ACCESS EXCLUSIVE MODE"

    execute """
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM connect_grants WHERE resource_type = 'connect_credential') THEN
        RAISE EXCEPTION 'cannot roll back: canonical Connect grants exist';
      END IF;
      IF EXISTS (SELECT 1 FROM connect_credentials
                 WHERE personal_credential_policy <> 'disabled' OR secret_binding <> 'configuration') THEN
        RAISE EXCEPTION 'cannot roll back: canonical Connect configuration exists';
      END IF;
    END $$
    """

    drop index(:connect_grants, [:credential_id], name: :connect_grants_credential_org_index)

    drop index(:connect_grants, [:credential_id, :owner_id],
           name: :connect_grants_credential_person_index
         )

    drop constraint(:connect_grants, :connect_grants_owner_check)
    drop constraint(:connect_grants, :connect_grants_resource_check)

    drop constraint(:connect_credentials, :connect_credentials_personal_policy_check)
    drop constraint(:connect_credentials, :connect_credentials_secret_binding_check)

    alter table(:connect_credentials) do
      remove :personal_credential_policy
      remove :secret_binding
    end
  end
end
