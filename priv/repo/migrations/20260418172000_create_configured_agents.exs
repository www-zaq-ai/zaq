defmodule Zaq.Repo.Migrations.CreateConfiguredAgents do
  use Ecto.Migration

  def change do
    create table(:configured_agents) do
      add :name, :string, null: false
      add :description, :text
      add :job, :text, null: false
      add :model, :string, null: false
      add :enabled_tool_keys, {:array, :string}, null: false, default: []
      add :conversation_enabled, :boolean, null: false, default: false
      add :strategy, :string, null: false, default: "react"
      add :advanced_options, :map, null: false, default: %{}
      add :active, :boolean, null: false, default: true

      add :credential_id,
          references(:ai_provider_credentials, on_delete: :restrict, type: :bigint),
          null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:configured_agents, [:name])
    create index(:configured_agents, [:credential_id])
    create index(:configured_agents, [:active])
    create index(:configured_agents, [:conversation_enabled])
  end
end
