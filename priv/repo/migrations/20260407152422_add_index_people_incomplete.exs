defmodule Zaq.Repo.Migrations.AddIndexPeopleIncomplete do
  use Ecto.Migration

  def change do
    create index(:people, [:incomplete])
  end
end
