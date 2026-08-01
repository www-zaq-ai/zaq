defmodule Zaq.Repo.Migrations.ReplaceSkillResourceRootWithResources do
  use Ecto.Migration

  # `resource_root` pointed at a directory and let a skill's files be found by path.
  # References are now stored by document id, so the path is no longer the identity and a
  # rename can no longer orphan anything. No backfill: the feature has not shipped.
  #
  # The top-level key is a namespace so `"skills"` and `"assets"` can join later without
  # another migration.
  def up do
    alter table(:agent_skills) do
      remove :resource_root
      add :resources, :map, null: false, default: %{"references" => []}
    end
  end

  def down do
    alter table(:agent_skills) do
      remove :resources
      add :resource_root, :string
    end
  end
end
