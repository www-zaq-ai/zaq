defmodule Zaq.Repo.Migrations.AddEveryoneSystemTeam do
  use Ecto.Migration

  def up do
    alter table(:teams) do
      add :system_key, :string
    end

    create unique_index(:teams, [:system_key], where: "system_key IS NOT NULL")

    execute """
    INSERT INTO teams (name, description, system_key, inserted_at, updated_at)
    VALUES ('Everyone', 'System team representing public access.', 'everyone', now(), now())
    ON CONFLICT (system_key) WHERE system_key IS NOT NULL DO UPDATE
    SET name = EXCLUDED.name,
        description = EXCLUDED.description,
        updated_at = now()
    """

    execute """
    INSERT INTO resource_permissions (resource_type, resource_id, team_id, access_rights, inserted_at, updated_at)
    SELECT 'document', d.id::text, t.id, ARRAY['read']::varchar[], now(), now()
    FROM documents d
    CROSS JOIN teams t
    WHERE t.system_key = 'everyone'
      AND d.tags @> ARRAY['public']::varchar[]
    ON CONFLICT (resource_type, resource_id, team_id) WHERE team_id IS NOT NULL DO NOTHING
    """

    execute """
    INSERT INTO resource_permissions (resource_type, resource_id, team_id, access_rights, inserted_at, updated_at)
    SELECT 'storage_entry', e.id::text, t.id, ARRAY['read']::varchar[], now(), now()
    FROM folder_settings fs
    JOIN storage_entries e
      ON e.volume = fs.volume_name
     AND e.relative_path = fs.folder_path
     AND e.kind = 'directory'
     AND e.deleted_at IS NULL
    CROSS JOIN teams t
    WHERE t.system_key = 'everyone'
      AND fs.tags @> ARRAY['public']::varchar[]
    ON CONFLICT (resource_type, resource_id, team_id) WHERE team_id IS NOT NULL DO NOTHING
    """

    drop index(:documents, [:tags])

    alter table(:documents) do
      remove :tags
    end

    drop table(:folder_settings)
  end

  def down do
    create table(:folder_settings) do
      add :volume_name, :string, null: false
      add :folder_path, :string, null: false
      add :tags, {:array, :string}, default: [], null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:folder_settings, [:volume_name, :folder_path])

    alter table(:documents) do
      add :tags, {:array, :string}, default: [], null: false
    end

    create index(:documents, [:tags], using: "GIN")

    execute """
    UPDATE documents d
    SET tags = array_append(d.tags, 'public')
    FROM resource_permissions p
    JOIN teams t ON t.id = p.team_id
    WHERE p.resource_type = 'document'
      AND p.resource_id = d.id::text
      AND t.system_key = 'everyone'
      AND NOT d.tags @> ARRAY['public']::varchar[]
    """

    execute """
    INSERT INTO folder_settings (volume_name, folder_path, tags, inserted_at, updated_at)
    SELECT e.volume, e.relative_path, ARRAY['public']::varchar[], now(), now()
    FROM resource_permissions p
    JOIN teams t ON t.id = p.team_id
    JOIN storage_entries e ON p.resource_type = 'storage_entry' AND p.resource_id = e.id::text
    WHERE t.system_key = 'everyone'
      AND e.kind = 'directory'
      AND e.deleted_at IS NULL
    ON CONFLICT (volume_name, folder_path) DO NOTHING
    """

    execute """
    DELETE FROM resource_permissions
    USING teams
    WHERE resource_permissions.team_id = teams.id
      AND teams.system_key = 'everyone'
      AND resource_permissions.resource_type = 'document'
    """

    execute "DELETE FROM teams WHERE system_key = 'everyone'"

    drop_if_exists unique_index(:teams, [:system_key], where: "system_key IS NOT NULL")

    alter table(:teams) do
      remove :system_key
    end
  end
end
