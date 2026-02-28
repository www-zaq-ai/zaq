defmodule Zaq.Repo.Migrations.CreateRolesAndUsers do
  use Ecto.Migration

  def change do
    create table(:roles) do
      add :name, :string, null: false
      add :meta, :map, default: %{}
      timestamps()
    end

    create unique_index(:roles, [:name])

    create table(:users) do
      add :username, :string, null: false
      add :password_hash, :string
      add :role_id, references(:roles, on_delete: :restrict), null: false
      add :must_change_password, :boolean, default: true
      timestamps()
    end

    create unique_index(:users, [:username])
  end
end
