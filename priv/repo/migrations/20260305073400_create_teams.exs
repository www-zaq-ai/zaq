defmodule Zaq.Repo.Migrations.CreateTeams do
  use Ecto.Migration

  def up do
    create_if_not_exists table(:teams) do
      add :name, :string, null: false
      add :description, :string

      timestamps(type: :utc_datetime)
    end

    create_if_not_exists unique_index(:teams, [:name])
  end

  def down do
    drop_if_exists table(:teams)
  end
end
