defmodule Zaq.Repo.Migrations.MoveDecisionModelToGlobal do
  use Ecto.Migration

  def up do
    configs = if prefix(), do: "#{prefix()}.system_configs", else: "system_configs"

    execute("""
    INSERT INTO #{configs} (key, value, inserted_at, updated_at)
    SELECT replace(key, 'rag.decision.', 'global.decision_model.'), value, NOW(), NOW()
    FROM #{configs}
    WHERE key IN ('rag.decision.credential_id', 'rag.decision.model')
      AND NOT EXISTS (
        SELECT 1 FROM #{configs}
        WHERE key IN ('global.decision_model.credential_id', 'global.decision_model.model')
      )
    ON CONFLICT (key) DO NOTHING
    """)
  end

  # Global settings may have been edited since rollout; preserve them on downgrade.
  def down, do: :ok
end
