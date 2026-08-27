defmodule Zaq.Repo.Migrations.RemovePersistedSidecars do
  use Ecto.Migration

  def up do
    execute("""
    DELETE FROM resource_permissions
    WHERE resource_type = 'document'
      AND resource_id IN (
        SELECT id::text FROM documents WHERE metadata ? 'source_document_source'
      )
    """)

    execute("""
    DELETE FROM documents
    WHERE metadata ? 'source_document_source'
    """)

    execute("""
    UPDATE documents
    SET metadata = COALESCE(metadata, '{}'::jsonb) - 'sidecar_source'
    WHERE metadata ? 'sidecar_source'
    """)
  end

  def down do
    :ok
  end
end
