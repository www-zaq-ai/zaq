defmodule Zaq.Repo.Migrations.AddIdleTimeAndMemoryContextToConfiguredAgents do
  use Ecto.Migration

  def change do
    alter table(:configured_agents) do
      add :idle_time_seconds, :integer, null: true
      add :memory_context_max_size, :integer, null: true
    end
  end
end
