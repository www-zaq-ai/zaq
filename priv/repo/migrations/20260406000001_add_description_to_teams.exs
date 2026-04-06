defmodule Zaq.Repo.Migrations.AddDescriptionToTeams do
  use Ecto.Migration

  def up do
    alter table(:teams) do
      add_if_not_exists :description, :string
    end
  end

  def down do
    alter table(:teams) do
      remove_if_exists :description, :string
    end
  end
end
