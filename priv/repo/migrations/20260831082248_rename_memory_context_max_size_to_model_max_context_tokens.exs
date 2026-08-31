defmodule Zaq.Repo.Migrations.RenameMemoryContextMaxSizeToModelMaxContextTokens do
  use Ecto.Migration

  def up do
    rename table(:configured_agents), :memory_context_max_size, to: :model_max_context_tokens

    execute """
    UPDATE configured_agents
    SET model_max_context_tokens = 5000
    WHERE model_max_context_tokens IS NULL
    """

    alter table(:configured_agents) do
      modify :model_max_context_tokens, :integer, null: false, default: 5000
    end
  end

  def down do
    alter table(:configured_agents) do
      modify :model_max_context_tokens, :integer, null: true, default: nil
    end

    rename table(:configured_agents), :model_max_context_tokens, to: :memory_context_max_size
  end
end
