defmodule Zaq.Repo.Migrations.SnapshotOperationModels do
  use Ecto.Migration

  def up do
    configs = if prefix(), do: "#{prefix()}.system_configs", else: "system_configs"

    # Only configured legacy installations are copied. Never keep a live link to
    # llm.* and never overwrite a dedicated selection on repeated rollout.
    for destination <- ["rag.translation", "global.small_model"] do
      execute("""
      INSERT INTO #{configs} (key, value, inserted_at, updated_at)
      SELECT '#{destination}.' || field,
        COALESCE((SELECT value FROM #{configs} WHERE key = 'llm.' || field),
          CASE field WHEN 'temperature' THEN '0.0' WHEN 'top_p' THEN '0.9' END),
        NOW(), NOW()
      FROM unnest(ARRAY['credential_id', 'model', 'temperature', 'top_p']) AS field
      WHERE EXISTS (SELECT 1 FROM #{configs} WHERE key = 'llm.credential_id' AND value IS NOT NULL AND value != '')
        AND EXISTS (SELECT 1 FROM #{configs} WHERE key = 'llm.model' AND value IS NOT NULL AND value != '')
        AND NOT EXISTS (SELECT 1 FROM #{configs} WHERE key LIKE '#{destination}.%')
      ON CONFLICT (key) DO NOTHING
      """)
    end
  end

  # Configuration may have been edited since rollout; never delete it on downgrade.
  def down, do: :ok
end
