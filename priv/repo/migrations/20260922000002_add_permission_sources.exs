defmodule Zaq.Repo.Migrations.AddPermissionSources do
  use Ecto.Migration

  def up do
    alter table(:resource_permissions) do
      add :source_key, :string, null: false, default: "manual"
    end

    execute "DROP INDEX uix_resource_perm_person"
    execute "DROP INDEX uix_resource_perm_team"

    execute """
    CREATE UNIQUE INDEX uix_resource_perm_person
      ON resource_permissions (resource_type, resource_id, person_id, source_key)
      WHERE person_id IS NOT NULL
    """

    execute """
    CREATE UNIQUE INDEX uix_resource_perm_team
      ON resource_permissions (resource_type, resource_id, team_id, source_key)
      WHERE team_id IS NOT NULL
    """
  end

  def down do
    execute """
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM resource_permissions WHERE source_key <> 'manual') THEN
        RAISE EXCEPTION 'Cannot remove permission sources while provider grants exist';
      END IF;
    END $$
    """

    execute "DROP INDEX uix_resource_perm_person"
    execute "DROP INDEX uix_resource_perm_team"

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

    alter table(:resource_permissions) do
      remove :source_key
    end
  end
end
