defmodule Zaq.Repo.Migrations.AddMaxIterationsToConfiguredAgents do
  use Ecto.Migration

  def change do
    alter table(:configured_agents) do
      add :max_iterations, :integer, null: true
    end
  end
end
