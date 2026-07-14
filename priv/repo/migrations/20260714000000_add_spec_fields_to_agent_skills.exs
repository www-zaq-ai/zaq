defmodule Zaq.Repo.Migrations.AddSpecFieldsToAgentSkills do
  use Ecto.Migration

  def up do
    alter table(:agent_skills) do
      add :provided_tool_keys, {:array, :string}, null: false, default: []
      add :allowed_tools, {:array, :string}, null: false, default: []
      add :resource_root, :string
      add :diagnostics, :map
    end

    # `provided_tool_keys` is the new home of `tool_keys`: the ZAQ tool modules we
    # provision when a skill is attached. `tool_keys` is deliberately KEPT and
    # dual-written for the rollout window — roles deploy as separate containers, so a
    # node still running the old code would read a column that a rename had removed.
    # It is dropped in a follow-up migration once the new code is on every node.
    execute "UPDATE agent_skills SET provided_tool_keys = tool_keys"

    # `allowed_tools` is deliberately NOT backfilled from `tool_keys`. It is the Open
    # Agent Skills field for "tools this skill is permitted to use" — a different
    # concept from the tool modules ZAQ provisions, and conflating the two is the exact
    # defect this migration exists to separate. Part 1 stores and renders it but does
    # not enforce it, so an empty list is inert rather than fail-open.
    execute "UPDATE agent_skills SET allowed_tools = '{}'"
  end

  def down do
    alter table(:agent_skills) do
      remove :provided_tool_keys
      remove :allowed_tools
      remove :resource_root
      remove :diagnostics
    end
  end
end
