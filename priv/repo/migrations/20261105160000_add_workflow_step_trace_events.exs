defmodule Zaq.Repo.Migrations.AddWorkflowStepTraceEvents do
  use Ecto.Migration

  def change do
    alter table(:workflow_action_results) do
      add :trace_events, {:array, :map}, default: [], null: false
    end
  end
end
