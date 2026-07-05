defmodule Zaq.Repo.Migrations.AddEnabledSkillIdsToConfiguredAgents do
  use Ecto.Migration

  def change do
    alter table(:configured_agents) do
      add :enabled_skill_ids, {:array, :integer}, null: false, default: []
    end

    create index(:configured_agents, [:enabled_skill_ids], using: "GIN")
  end
end
