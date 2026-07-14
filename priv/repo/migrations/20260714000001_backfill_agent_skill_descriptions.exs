defmodule Zaq.Repo.Migrations.BackfillAgentSkillDescriptions do
  use Ecto.Migration

  # `description` is REQUIRED by the Open Agent Skills spec (1-1024 chars, non-empty),
  # and `Jido.AI.Skill.Loader.parse/3` rejects a nil description outright in strict mode.
  #
  # ZAQ's schema had it optional. A row with a null or blank description would therefore
  # fail validation, fail `Skills.to_spec/1`, and — because invalid records are skipped
  # rather than crashing agent boot — SILENTLY VANISH from the skill index: invisible to
  # the model, unloadable, with no error surfaced to anyone.
  #
  # Backfill a placeholder rather than deleting or nulling out the record. It is
  # deliberately conspicuous: it reaches the model in the prompt index, so an operator
  # sees the consequence and fixes it, instead of the skill disappearing silently.
  @placeholder "TODO: describe what this skill does and when to use it."

  def up do
    execute """
    UPDATE agent_skills
       SET description = '#{@placeholder}'
     WHERE description IS NULL
        OR btrim(description) = ''
    """

    # NOT NULL is deliberately NOT added here. During a rolling deploy a node still
    # running the old code can insert a skill with a nil description; a NOT NULL
    # constraint would crash it. The changeset enforces the requirement for all new
    # code, and the constraint lands in Step 7 alongside the `tool_keys` drop, once
    # every node runs the new code.
  end

  def down do
    execute """
    UPDATE agent_skills
       SET description = NULL
     WHERE description = '#{@placeholder}'
    """
  end
end
