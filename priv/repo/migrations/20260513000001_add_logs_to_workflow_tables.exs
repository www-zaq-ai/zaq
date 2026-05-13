defmodule Zaq.Repo.Migrations.AddLogsToWorkflowTables do
  use Ecto.Migration

  def change do
    alter table(:workflow_action_results) do
      add :logs, {:array, :map}, null: false, default: []
    end

    alter table(:workflow_runs) do
      add :log_summary, :map
    end
  end
end
