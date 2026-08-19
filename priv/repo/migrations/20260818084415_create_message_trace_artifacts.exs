defmodule Zaq.Repo.Migrations.CreateMessageTraceArtifacts do
  use Ecto.Migration

  def change do
    create table(:message_trace_artifacts, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :message_id, references(:messages, type: :binary_id, on_delete: :delete_all),
        null: false

      add :tool_call_id, :string, null: false
      add :tool_name, :string, null: false
      add :name, :string, null: false
      add :mime_type, :string, null: false
      add :size, :bigint, null: false
      add :sha256, :binary, null: false
      add :content, :binary, null: false
      add :record, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:message_trace_artifacts, [:message_id])
    create index(:message_trace_artifacts, [:message_id, :tool_call_id])
  end
end
