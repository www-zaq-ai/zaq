defmodule Zaq.Repo.Migrations.AddTranscriptPersonOwner do
  use Ecto.Migration

  def up do
    alter table(:transcripts) do
      add :owner_person_id, references(:people, on_delete: :restrict)
    end

    create index(:transcripts, [:owner_person_id])

    create constraint(:transcripts, :transcripts_owner_strategy_check,
             check: """
             (strategy = 'shared' AND owner_person_id IS NULL)
             OR (strategy IN ('direct', 'replicated') AND owner_person_id IS NOT NULL)
             """
           )
  end

  def down do
    execute("""
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM transcripts WHERE owner_person_id IS NOT NULL LIMIT 1) THEN
        RAISE EXCEPTION 'Cannot remove transcript Person ownership while histories exist';
      END IF;
    END $$
    """)

    drop constraint(:transcripts, :transcripts_owner_strategy_check)
    drop index(:transcripts, [:owner_person_id])

    alter table(:transcripts) do
      remove :owner_person_id
    end
  end
end
