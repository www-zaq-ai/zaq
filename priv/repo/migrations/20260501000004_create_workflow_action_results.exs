defmodule Zaq.Repo.Migrations.CreateWorkflowActionResults do
  use Ecto.Migration

  def change do
    create table(:workflow_action_results, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workflow_run_id, references(:workflow_runs, type: :binary_id, on_delete: :delete_all),
        null: false

      add :step_name, :string, null: false
      add :step_index, :integer, null: false
      add :status, :string, null: false, default: "running"
      add :results, :map
      add :errors, :map
      add :logs, {:array, :map}, null: false, default: []
      add :started_at, :utc_datetime
      add :finished_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    # Primary rehydration query: ordered step history for a run
    create index(:workflow_action_results, [:workflow_run_id, :step_index])
  end
end
