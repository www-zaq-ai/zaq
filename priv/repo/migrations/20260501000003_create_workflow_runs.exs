defmodule Zaq.Repo.Migrations.CreateWorkflowRuns do
  use Ecto.Migration

  def change do
    create table(:workflow_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      # No on_delete: :delete_all — archiving a workflow must not wipe run history
      add :workflow_id, references(:workflows, type: :binary_id), null: false
      add :steps_snapshot, :map, null: false
      add :settings_snapshot, :map, null: false, default: %{}
      add :status, :string, null: false, default: "pending"
      add :source_event, :map, null: false
      add :started_at, :utc_datetime
      add :finished_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:workflow_runs, [:workflow_id])
    create index(:workflow_runs, [:status])
  end
end
