defmodule Zaq.Repo.Migrations.AddInputToWorkflowActionResults do
  use Ecto.Migration

  def change do
    alter table(:workflow_action_results) do
      add :input, :map
    end
  end
end
