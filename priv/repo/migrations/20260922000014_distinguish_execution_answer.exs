defmodule Zaq.Repo.Migrations.DistinguishExecutionAnswer do
  use Ecto.Migration

  def change do
    create constraint(:execution_records, :execution_records_distinct_answer_check,
             check:
               "public_answer_message_id IS NULL OR public_answer_message_id <> user_message_id"
           )
  end
end
