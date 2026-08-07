defmodule Zaq.Repo.Migrations.CreateMessageTraceArtifacts do
  use Ecto.Migration

  def up do
    create table(:message_trace_artifacts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tool_call_id, :string, null: false
      add :name, :string
      add :mime_type, :string
      add :size, :integer
      add :content, :binary

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:message_trace_artifacts, [:tool_call_id])

    # Attachments are already-compressed media, so pglz gains nothing and costs CPU on every
    # write. EXTERNAL keeps the out-of-line storage and skips the compression attempt.
    execute("ALTER TABLE message_trace_artifacts ALTER COLUMN content SET STORAGE EXTERNAL")
  end

  def down do
    drop table(:message_trace_artifacts)
  end
end
