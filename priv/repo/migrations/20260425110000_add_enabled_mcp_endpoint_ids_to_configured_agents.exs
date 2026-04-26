defmodule Zaq.Repo.Migrations.AddEnabledMcpEndpointIdsToConfiguredAgents do
  use Ecto.Migration

  def change do
    alter table(:configured_agents) do
      add :enabled_mcp_endpoint_ids, {:array, :bigint}, null: false, default: []
    end
  end
end
