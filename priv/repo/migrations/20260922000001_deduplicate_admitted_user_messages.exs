defmodule Zaq.Repo.Migrations.DeduplicateAdmittedUserMessages do
  use Ecto.Migration

  def up do
    execute("""
    CREATE UNIQUE INDEX messages_admitted_external_id_index
    ON messages (conversation_id, (metadata->>'external_message_id'))
    WHERE role = 'user'
      AND metadata->>'execution_status' IS NOT NULL
      AND metadata->>'external_message_id' IS NOT NULL
    """)
  end

  def down do
    execute("DROP INDEX messages_admitted_external_id_index")
  end
end
