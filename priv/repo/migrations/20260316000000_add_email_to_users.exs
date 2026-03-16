defmodule Zaq.Repo.Migrations.AddEmailToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :email, :string
    end

    create unique_index(:users, [:email], where: "email IS NOT NULL")
  end
end
