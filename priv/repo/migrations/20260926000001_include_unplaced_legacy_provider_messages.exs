defmodule Zaq.Repo.Migrations.IncludeUnplacedLegacyProviderMessages do
  use Ecto.Migration

  @moduledoc """
  Forward-only correction for legacy admitted messages with provider IDs that
  were never placed in a canonical transcript. Existing placements, UUIDs,
  ratings and private metadata remain untouched.
  """

  def up do
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
        WHERE m.conversation_id = c.id AND m.source_provider IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM transcript_messages p WHERE p.message_id = m.id)
      )
      ON CONFLICT DO NOTHING
      """,
      """
      WITH missing AS (
        SELECT t.id AS transcript_id, m.id AS message_id, t.next_position +
               row_number() OVER (PARTITION BY t.id ORDER BY m.inserted_at, m.id) AS position
        FROM transcripts t
        JOIN messages m ON m.conversation_id = t.conversation_id
        WHERE t.strategy = 'legacy' AND m.source_provider IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM transcript_messages p WHERE p.message_id = m.id)
      )
      INSERT INTO transcript_messages
        (id, transcript_id, message_id, position, provenance, inserted_at)
      SELECT gen_random_uuid(), transcript_id, message_id, position, 'legacy_restricted', now()
      FROM missing
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
      IF EXISTS (SELECT 1 FROM transcript_messages WHERE provenance = 'legacy_restricted' LIMIT 1) THEN
        RAISE EXCEPTION 'Cannot discard restricted legacy placements';
      END IF;
    END $$
    """)
  end
end
