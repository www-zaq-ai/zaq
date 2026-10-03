defmodule Zaq.Repo.Migrations.RestrictLegacyChannelHistory do
  use Ecto.Migration

  @moduledoc """
  Adds a restricted structural snapshot of legacy conversations. Original
  messages and every dependent foreign key stay in place. These transcripts
  are never eligible for channel grants or automatic agent hydration.
  """

  def up do
    drop constraint(:transcripts, :transcripts_strategy_check)
    drop constraint(:transcripts, :transcripts_owner_strategy_check)

    create constraint(:transcripts, :transcripts_strategy_check,
             check: "strategy IN ('direct', 'shared', 'replicated', 'legacy')"
           )

    create constraint(:transcripts, :transcripts_owner_strategy_check,
             check: """
             (strategy IN ('direct', 'shared', 'legacy') AND owner_person_id IS NULL)
             OR (strategy = 'replicated' AND owner_person_id IS NOT NULL)
             """
           )

    Enum.each(backfill_statements(), &execute/1)
  end

  @doc false
  def backfill_statements do
    [
      """
      INSERT INTO transcripts
        (id, strategy, provider, scope_key, external_channel_id, external_thread_id,
         conversation_id, permission_resource_type, permission_resource_id,
         next_position, inserted_at, updated_at)
      SELECT gen_random_uuid(), 'legacy', 'legacy', 'legacy:' || c.id::text,
             c.external_channel_id, c.external_thread_id, c.id,
             'legacy_conversation', c.id::text, 0, now(), now()
      FROM conversations c
      WHERE EXISTS (
        SELECT 1 FROM messages m
        WHERE m.conversation_id = c.id AND m.source_provider IS NULL
          AND NOT EXISTS (
            SELECT 1 FROM transcript_messages p WHERE p.message_id = m.id
          )
      )
        AND NOT EXISTS (
          SELECT 1 FROM transcripts t WHERE t.conversation_id = c.id AND t.strategy = 'legacy'
        )
      ON CONFLICT DO NOTHING
      """,
      """
      WITH ordered AS (
        SELECT t.id AS transcript_id, m.id AS message_id,
               row_number() OVER (PARTITION BY t.id ORDER BY m.inserted_at, m.id) AS position
        FROM transcripts t
        JOIN messages m ON m.conversation_id = t.conversation_id
          AND m.source_provider IS NULL
          AND NOT EXISTS (
            SELECT 1 FROM transcript_messages current_p
            WHERE current_p.message_id = m.id AND current_p.provenance <> 'legacy_restricted'
          )
        WHERE t.strategy = 'legacy'
      )
      INSERT INTO transcript_messages
        (id, transcript_id, message_id, position, provenance, inserted_at)
      SELECT gen_random_uuid(), transcript_id, message_id, position, 'legacy_restricted', now()
      FROM ordered
      ON CONFLICT DO NOTHING
      """,
      """
      UPDATE transcripts t
      SET next_position = (
        SELECT COALESCE(MAX(p.position), 0)
        FROM transcript_messages p WHERE p.transcript_id = t.id
      )
      WHERE t.strategy = 'legacy'
      """
    ]
  end

  def down do
    execute("""
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM transcripts WHERE strategy = 'legacy' LIMIT 1) THEN
        RAISE EXCEPTION 'Cannot discard populated restricted legacy transcripts';
      END IF;
    END $$
    """)

    drop constraint(:transcripts, :transcripts_strategy_check)
    drop constraint(:transcripts, :transcripts_owner_strategy_check)

    create constraint(:transcripts, :transcripts_strategy_check,
             check: "strategy IN ('direct', 'shared', 'replicated')"
           )

    create constraint(:transcripts, :transcripts_owner_strategy_check,
             check: """
             (strategy IN ('direct', 'shared') AND owner_person_id IS NULL)
             OR (strategy = 'replicated' AND owner_person_id IS NOT NULL)
             """
           )
  end
end
