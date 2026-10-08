defmodule Zaq.Repo.Migrations.AddCommunicationScopeToConversations do
  use Ecto.Migration

  def up do
    alter table(:conversations) do
      add :external_channel_id, :string
      add :external_thread_id, :string
    end

    create index(:conversations, [:channel_type, :channel_config_id, :external_channel_id])

    execute("""
    CREATE UNIQUE INDEX conversations_active_communication_scope_index
    ON conversations (
      channel_type,
      COALESCE(channel_config_id, -1),
      external_channel_id,
      COALESCE(external_thread_id, ''),
      channel_user_id
    )
    WHERE status = 'active'
      AND external_channel_id IS NOT NULL
      AND channel_user_id IS NOT NULL
    """)
  end

  def down do
    execute("DROP INDEX conversations_active_communication_scope_index")
    drop index(:conversations, [:channel_type, :channel_config_id, :external_channel_id])

    alter table(:conversations) do
      remove :external_thread_id
      remove :external_channel_id
    end
  end
end
