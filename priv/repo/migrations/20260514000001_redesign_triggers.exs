defmodule Zaq.Repo.Migrations.RedesignTriggers do
  use Ecto.Migration

  def change do
    # Drop old workflow-scoped indices and FK column
    drop index(:triggers, [:workflow_id, :enabled])
    drop index(:triggers, [:workflow_id])

    alter table(:triggers) do
      remove :workflow_id, references(:workflows, type: :binary_id, on_delete: :delete_all)
      add :execution_mode, :string, null: false, default: "parallel"
      add :max_concurrency, :integer, null: true
      add :on_failure, :string, null: false, default: "continue"
    end

    create index(:triggers, [:enabled])

    # Triggers → Workflows (many-to-many, ordered)
    create table(:trigger_workflows, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :trigger_id, references(:triggers, type: :binary_id, on_delete: :delete_all),
        null: false

      add :workflow_id, references(:workflows, type: :binary_id, on_delete: :delete_all),
        null: false

      add :position, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:trigger_workflows, [:trigger_id])
    create index(:trigger_workflows, [:workflow_id])
    create unique_index(:trigger_workflows, [:trigger_id, :workflow_id])

    # Triggers → Triggers (self-referential chain)
    create table(:trigger_chains, primary_key: false) do
      add :trigger_id, references(:triggers, type: :binary_id, on_delete: :delete_all),
        null: false

      add :downstream_trigger_id, references(:triggers, type: :binary_id, on_delete: :delete_all),
        null: false
    end

    create index(:trigger_chains, [:trigger_id])
    create index(:trigger_chains, [:downstream_trigger_id])
    create unique_index(:trigger_chains, [:trigger_id, :downstream_trigger_id])
  end
end
