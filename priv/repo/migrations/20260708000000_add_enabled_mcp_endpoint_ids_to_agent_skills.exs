defmodule Zaq.Repo.Migrations.AddEnabledMcpEndpointIdsToAgentSkills do
  use Ecto.Migration

  def change do
    alter table(:agent_skills) do
      add :enabled_mcp_endpoint_ids, {:array, :integer}, null: false, default: []
    end

    create index(:agent_skills, [:enabled_mcp_endpoint_ids], using: "GIN")
  end
end
