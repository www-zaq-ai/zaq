defmodule Zaq.Repo.Migrations.AddTeamIdsToPeople do
  use Ecto.Migration

  def up do
    alter table(:people) do
      add_if_not_exists :team_ids, {:array, :integer}, default: []
    end
  end

  def down do
    alter table(:people) do
      remove_if_exists :team_ids, {:array, :integer}
    end
  end
end
