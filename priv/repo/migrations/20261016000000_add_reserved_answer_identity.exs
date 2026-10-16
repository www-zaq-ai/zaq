defmodule Zaq.Repo.Migrations.AddReservedAnswerIdentity do
  use Ecto.Migration

  def up do
    alter table(:execution_records) do
      add :reserved_answer_message_id, :uuid
    end

    # Completed roots already have authoritative identity; never replace it.
    execute("""
    UPDATE execution_records
    SET reserved_answer_message_id = public_answer_message_id
    WHERE public_answer_message_id IS NOT NULL
    """)

    create unique_index(:execution_records, [:reserved_answer_message_id])

    create constraint(:execution_records, :execution_records_answer_reservation_check,
             check: """
             reserved_answer_message_id IS NULL OR (
               root_execution_id IS NULL AND
               reserved_answer_message_id <> user_message_id AND
               (public_answer_message_id IS NULL OR
                public_answer_message_id = reserved_answer_message_id)
             )
             """
           )
  end

  def down do
    execute("""
    DO $$ BEGIN
      IF EXISTS (
        SELECT 1 FROM execution_records
        WHERE reserved_answer_message_id IS NOT NULL AND public_answer_message_id IS NULL
      ) THEN
        RAISE EXCEPTION 'Cannot remove reserved answer identities without persisted answers';
      END IF;
    END $$
    """)

    drop constraint(:execution_records, :execution_records_answer_reservation_check)
    drop unique_index(:execution_records, [:reserved_answer_message_id])

    alter table(:execution_records) do
      remove :reserved_answer_message_id
    end
  end
end
