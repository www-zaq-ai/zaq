defmodule Zaq.Repo.Migrations.CreateWorkflows do
  use Ecto.Migration

  def change do
    create table(:workflows, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :description, :string
      add :status, :string, null: false, default: "draft"
      add :nodes, :map, null: false, default: "[]"
      add :edges, :map, null: false, default: "[]"
      add :settings, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create index(:workflows, [:status])
  end
end
