defmodule Zaq.Repo.Migrations.AddConfiguredAgentIdToRetrievalChannels do
  use Ecto.Migration

  def change do
    alter table(:retrieval_channels) do
      add :configured_agent_id,
          references(:configured_agents, on_delete: :nilify_all, type: :bigint),
          null: true
    end

    create index(:retrieval_channels, [:configured_agent_id])
  end
end
