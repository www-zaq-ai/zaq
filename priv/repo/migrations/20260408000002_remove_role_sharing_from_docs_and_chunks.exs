defmodule Zaq.Repo.Migrations.RemoveRoleSharingFromDocsAndChunks do
  use Ecto.Migration

  def up do
    alter table(:documents) do
      remove :role_id
      remove :shared_role_ids
    end

    # chunks table may have been dropped and recreated fresh (see reset_ingestion migration).
    # Only drop columns if they exist.
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'chunks' AND column_name = 'role_id'
      ) THEN
        ALTER TABLE chunks DROP COLUMN role_id;
      END IF;
      IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'chunks' AND column_name = 'shared_role_ids'
      ) THEN
        ALTER TABLE chunks DROP COLUMN shared_role_ids;
      END IF;
    END $$;
    """)

    alter table(:ingest_jobs) do
      remove :role_id
      remove :shared_role_ids
    end
  end

  def down do
    alter table(:documents) do
      add :role_id, references(:roles, on_delete: :nilify_all)
      add :shared_role_ids, {:array, :integer}, default: []
    end

    execute("""
    ALTER TABLE chunks
      ADD COLUMN IF NOT EXISTS role_id bigint REFERENCES roles(id) ON DELETE SET NULL,
      ADD COLUMN IF NOT EXISTS shared_role_ids integer[] DEFAULT '{}';
    """)

    alter table(:ingest_jobs) do
      add :role_id, :integer
      add :shared_role_ids, {:array, :integer}, default: []
    end
  end
end
