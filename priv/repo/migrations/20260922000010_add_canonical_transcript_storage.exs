defmodule Zaq.Repo.Migrations.AddCanonicalTranscriptStorage do
  use Ecto.Migration

  def up do
    # Keep legacy message UUIDs (and their rating/trace foreign keys) in place.
    # New canonical rows need not belong to exactly one legacy conversation.
    execute("ALTER TABLE messages ALTER COLUMN conversation_id DROP NOT NULL")

    alter table(:messages) do
      add :source_provider, :string
      add :source_account_key, :string
      add :external_message_id, :string
      add :author_id, :string
      add :author_name, :string
      add :provider_sent_at, :utc_datetime_usec
      add :attachments, {:array, :map}, null: false, default: []
    end

    create constraint(:messages, :messages_source_identity_check,
             check: """
             (source_provider IS NULL AND source_account_key IS NULL AND external_message_id IS NULL)
             OR (NULLIF(source_provider, '') IS NOT NULL
                 AND NULLIF(source_account_key, '') IS NOT NULL
                 AND NULLIF(external_message_id, '') IS NOT NULL)
             """
           )

    create unique_index(:messages, [:source_provider, :source_account_key, :external_message_id],
             where: "external_message_id IS NOT NULL",
             name: :messages_canonical_source_index
           )

    create table(:transcripts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :strategy, :string, null: false
      add :provider, :string, null: false
      add :channel_config_id, references(:channel_configs, on_delete: :restrict)
      add :scope_key, :string, null: false
      add :external_channel_id, :string
      add :external_thread_id, :string
      add :parent_id, references(:transcripts, type: :binary_id, on_delete: :restrict)
      add :conversation_id, references(:conversations, type: :binary_id, on_delete: :restrict)
      add :permission_resource_type, :string, null: false
      add :permission_resource_id, :string, null: false
      add :next_position, :bigint, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:transcripts, :transcripts_strategy_check,
             check: "strategy IN ('direct', 'shared', 'replicated')"
           )

    create constraint(:transcripts, :transcripts_next_position_check, check: "next_position >= 0")

    create index(:transcripts, [:parent_id])
    create index(:transcripts, [:conversation_id])

    execute("""
    CREATE UNIQUE INDEX transcripts_scope_index
    ON transcripts (provider, COALESCE(channel_config_id, -1), scope_key)
    """)

    create table(:transcript_messages, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :transcript_id, references(:transcripts, type: :binary_id, on_delete: :restrict),
        null: false

      add :message_id, references(:messages, type: :binary_id, on_delete: :restrict), null: false
      add :position, :bigint, null: false
      add :provenance, :string, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:transcript_messages, [:transcript_id, :message_id],
             name: :transcript_messages_message_index
           )

    create unique_index(:transcript_messages, [:transcript_id, :position],
             name: :transcript_messages_position_index
           )

    create constraint(:transcript_messages, :transcript_messages_position_check,
             check: "position > 0"
           )
  end

  def down do
    # An older schema cannot represent canonical-only messages or transcripts.
    # Refuse to discard their data during rollback.
    execute("""
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM transcripts LIMIT 1)
         OR EXISTS (
           SELECT 1 FROM messages
           WHERE conversation_id IS NULL
              OR source_provider IS NOT NULL
              OR source_account_key IS NOT NULL
              OR external_message_id IS NOT NULL
              OR author_id IS NOT NULL
              OR author_name IS NOT NULL
              OR provider_sent_at IS NOT NULL
              OR cardinality(attachments) > 0
           LIMIT 1
         ) THEN
        RAISE EXCEPTION 'Cannot remove populated canonical transcript storage';
      END IF;
    END $$
    """)

    drop table(:transcript_messages)
    drop table(:transcripts)

    drop index(:messages, [:source_provider, :source_account_key, :external_message_id],
           name: :messages_canonical_source_index
         )

    drop constraint(:messages, :messages_source_identity_check)

    alter table(:messages) do
      remove :source_provider
      remove :source_account_key
      remove :external_message_id
      remove :author_id
      remove :author_name
      remove :provider_sent_at
      remove :attachments
    end

    execute("ALTER TABLE messages ALTER COLUMN conversation_id SET NOT NULL")
  end
end
