defmodule Zaq.Repo.Migrations.CreateTriggers do
  use Ecto.Migration

  def change do
    create table(:triggers, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :event_name, :string, null: false, default: ""
      add :enabled, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    create index(:triggers, [:enabled])
    create index(:triggers, [:event_name])

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
  end
end
