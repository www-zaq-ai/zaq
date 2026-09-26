defmodule Zaq.Repo.Migrations.AlignDirectTranscriptGrants do
  use Ecto.Migration

  def up do
    drop constraint(:transcripts, :transcripts_owner_strategy_check)

    create constraint(:transcripts, :transcripts_owner_strategy_check,
             check: """
             (strategy IN ('direct', 'shared') AND owner_person_id IS NULL)
             OR (strategy = 'replicated' AND owner_person_id IS NOT NULL)
             """
           )
  end

  def down do
    execute("""
    DO $$ BEGIN
      IF EXISTS (
        SELECT 1 FROM transcripts
        WHERE strategy = 'direct' AND owner_person_id IS NULL LIMIT 1
      ) THEN
        RAISE EXCEPTION 'Cannot restore single-owner Direct constraint with grant-driven histories';
      END IF;
    END $$
    """)

    drop constraint(:transcripts, :transcripts_owner_strategy_check)

    create constraint(:transcripts, :transcripts_owner_strategy_check,
             check: """
             (strategy = 'shared' AND owner_person_id IS NULL)
             OR (strategy IN ('direct', 'replicated') AND owner_person_id IS NOT NULL)
             """
           )
  end
end
