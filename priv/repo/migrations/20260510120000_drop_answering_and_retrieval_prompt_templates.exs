defmodule Zaq.Repo.Migrations.DropAnsweringAndRetrievalPromptTemplates do
  use Ecto.Migration

  def up do
    execute("DELETE FROM prompt_templates WHERE slug IN ('answering', 'retrieval')")
  end

  def down do
    # Retrieval and answering prompts are now hardcoded in their respective modules.
    # No rollback: re-inserting stale DB rows would conflict with the hardcoded prompts.
    :ok
  end
end
