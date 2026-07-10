defmodule Zaq.Repo.Migrations.AddGinIndexToConfiguredAgentsMcpEndpointIds do
  use Ecto.Migration

  # Backs the `enabled_mcp_endpoint_ids @> ARRAY[?]` containment query in
  # `Zaq.Agent.list_agents_with_mcp_endpoint/1` (mirrors the GIN index already
  # present on `configured_agents.enabled_skill_ids`).
  def change do
    create index(:configured_agents, [:enabled_mcp_endpoint_ids], using: "GIN")
  end
end
