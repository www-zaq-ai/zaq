defmodule Zaq.Repo.Migrations.CreateExecutionRecords do
  use Ecto.Migration

  def up do
    create table(:execution_records, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :person_id, references(:people, on_delete: :restrict), null: false

      add :user_message_id, references(:messages, type: :binary_id, on_delete: :restrict),
        null: false

      add :public_answer_message_id,
          references(:messages, type: :binary_id, on_delete: :restrict)

      add :status, :string, null: false, default: "pending"
      add :finalization_token_hash, :string, null: false
      add :trace_entries, {:array, :map}, null: false, default: []
      add :tool_results, {:array, :map}, null: false, default: []
      add :usage, :map, null: false, default: %{}
      add :outcome, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:execution_records, [:person_id, :inserted_at])
    create index(:execution_records, [:user_message_id])

    create unique_index(:execution_records, [:public_answer_message_id],
             where: "public_answer_message_id IS NOT NULL",
             name: :execution_records_public_answer_index
           )

    create unique_index(:execution_records, [:finalization_token_hash])

    create constraint(:execution_records, :execution_records_status_check,
             check: "status IN ('pending', 'completed', 'failed')"
           )

    create constraint(:execution_records, :execution_records_answer_status_check,
             check: """
             (status = 'completed' AND public_answer_message_id IS NOT NULL)
             OR (status IN ('pending', 'failed') AND public_answer_message_id IS NULL)
             """
           )

    create constraint(:execution_records, :execution_records_capability_hash_check,
             check: "finalization_token_hash ~ '^[A-Za-z0-9+/]{43}=$'"
           )
  end

  def down do
    # Never destroy private traces or execution audit data through a rollback.
    execute("""
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM execution_records LIMIT 1) THEN
        RAISE EXCEPTION 'Cannot drop populated execution records';
      END IF;
    END $$
    """)

    drop table(:execution_records)
  end
end
