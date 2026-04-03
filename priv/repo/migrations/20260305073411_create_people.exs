defmodule Zaq.Repo.Migrations.CreatePeople do
  use Ecto.Migration

  # DDL originally applied by license_manager migration 20260305073411.
  # Uses create_if_not_exists so it is a no-op on shared prod/dev DBs
  # where the table already exists, but creates it in test environments.
  def up do
    create_if_not_exists table(:people) do
      add :full_name, :string, null: false
      add :email, :string
      add :role, :string
      add :status, :string, default: "active"
      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime)
    end

    create_if_not_exists unique_index(:people, [:email])
  end

  def down do
    drop_if_exists table(:people)
  end
end
