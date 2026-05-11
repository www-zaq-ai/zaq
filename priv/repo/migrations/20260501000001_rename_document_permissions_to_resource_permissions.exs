defmodule Zaq.Repo.Migrations.RenameDocumentPermissionsToResourcePermissions do
  use Ecto.Migration

  def up do
    rename table(:document_permissions), to: table(:resource_permissions)

    # Add new polymorphic columns before dropping document_id so data can be copied.
    # resource_id is a string to support both integer PKs (documents) and UUIDs (workflows).
    alter table(:resource_permissions) do
      add :resource_type, :string, null: false, default: "document"
      add :resource_id, :string
    end

    execute "UPDATE resource_permissions SET resource_id = document_id::text"
    execute "ALTER TABLE resource_permissions ALTER COLUMN resource_id SET NOT NULL"

    alter table(:resource_permissions) do
      remove :document_id
    end

    # Drop old document-scoped indexes
    execute "DROP INDEX IF EXISTS resource_permissions_document_id_index"
    execute "DROP INDEX IF EXISTS uix_doc_perm_person"
    execute "DROP INDEX IF EXISTS uix_doc_perm_team"

    # Drop old check constraint before recreating
    execute "ALTER TABLE resource_permissions DROP CONSTRAINT IF EXISTS check_person_or_team_present"

    create index(:resource_permissions, [:resource_type, :resource_id])
    create index(:resource_permissions, [:team_id])

    execute """
    CREATE UNIQUE INDEX uix_resource_perm_person
      ON resource_permissions (resource_type, resource_id, person_id)
      WHERE person_id IS NOT NULL
    """

    execute """
    CREATE UNIQUE INDEX uix_resource_perm_team
      ON resource_permissions (resource_type, resource_id, team_id)
      WHERE team_id IS NOT NULL
    """

    execute """
    ALTER TABLE resource_permissions
      ADD CONSTRAINT check_person_or_team_present
      CHECK (person_id IS NOT NULL OR team_id IS NOT NULL)
    """
  end

  def down do
    raise "Irreversible migration — cannot restore document_permissions safely after data migration"
  end
end
