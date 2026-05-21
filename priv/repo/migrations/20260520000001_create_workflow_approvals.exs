defmodule Zaq.Repo.Migrations.CreateWorkflowApprovals do
  use Ecto.Migration

  def change do
    create table(:workflow_approvals, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workflow_run_id,
          references(:workflow_runs, type: :binary_id, on_delete: :delete_all),
          null: false

      add :step_name, :string, null: false
      add :approval_token, :string, null: false
      add :message, :string
      add :status, :string, null: false, default: "pending"
      add :decision, :map
      add :approved_by, :string
      add :approved_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:workflow_approvals, [:workflow_run_id, :step_name])
    create unique_index(:workflow_approvals, [:approval_token])
  end
end
