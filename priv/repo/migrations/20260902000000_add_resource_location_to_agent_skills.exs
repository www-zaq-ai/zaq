defmodule Zaq.Repo.Migrations.AddResourceLocationToAgentSkills do
  use Ecto.Migration

  def up do
    alter table(:agent_skills) do
      add :license, :string
      add :compatibility, :string
      add :metadata, :map, null: false, default: %{}
      add :resource_provider, :string
      add :resource_config_id, :integer
      add :resource_scope_id, :string
      add :resource_folder_id, :string
      add :resource_folder_path, :string
      remove :diagnostics
      remove :tool_keys
    end
  end

  def down do
    alter table(:agent_skills) do
      add :tool_keys, {:array, :string}, null: false, default: []
      add :diagnostics, :map
      remove :license
      remove :compatibility
      remove :metadata
      remove :resource_provider
      remove :resource_config_id
      remove :resource_scope_id
      remove :resource_folder_id
      remove :resource_folder_path
    end

    execute "UPDATE agent_skills SET tool_keys = provided_tool_keys"
  end
end
