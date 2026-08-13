defmodule Zaq.Repo.Migrations.ReplaceSkillResourceRootWithResources do
  use Ecto.Migration

  def up do
    alter table(:agent_skills) do
      remove :resource_root
      add :resources, :map, null: false, default: %{}
    end
  end

  def down do
    alter table(:agent_skills) do
      add :resource_root, :string
      remove :resources
    end
  end
end
