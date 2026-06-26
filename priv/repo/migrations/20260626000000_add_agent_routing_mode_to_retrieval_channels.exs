defmodule Zaq.Repo.Migrations.AddAgentRoutingModeToRetrievalChannels do
  use Ecto.Migration

  def change do
    alter table(:retrieval_channels) do
      add :agent_routing_mode, :string
    end
  end
end
