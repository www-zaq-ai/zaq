defmodule Zaq.Repo.Migrations.RemoveCustomLoadSkillToolKeys do
  use Ecto.Migration

  @custom_load_skill_key "skills.load_skill"

  def up do
    execute("""
    UPDATE configured_agents
    SET enabled_tool_keys = ARRAY_REMOVE(enabled_tool_keys, '#{@custom_load_skill_key}')
    WHERE '#{@custom_load_skill_key}' = ANY(enabled_tool_keys)
    """)

    execute("""
    UPDATE agent_skills
    SET provided_tool_keys = ARRAY_REMOVE(provided_tool_keys, '#{@custom_load_skill_key}')
    WHERE '#{@custom_load_skill_key}' = ANY(provided_tool_keys)
    """)
  end

  def down, do: :ok
end
