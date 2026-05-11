defmodule Zaq.Repo.Migrations.CreateTriggers do
  use Ecto.Migration

  def change do
    create table(:triggers, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workflow_id, references(:workflows, type: :binary_id, on_delete: :delete_all),
        null: false

      add :type, :string, null: false
      add :config, :map, null: false, default: %{}
      add :enabled, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    create index(:triggers, [:workflow_id])
    create index(:triggers, [:type])
    create index(:triggers, [:workflow_id, :enabled])
  end
end
