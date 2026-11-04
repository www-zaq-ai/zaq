unless Code.ensure_loaded?(Zaq.Repo.Migrations.SnapshotOperationModels) do
  Code.require_file(
    "../../../priv/repo/migrations/20261031132000_snapshot_operation_models.exs",
    __DIR__
  )
end

defmodule Zaq.System.OperationModelsMigrationTest do
  use Zaq.DataCase, async: false
  alias Zaq.Repo.Migrations.SnapshotOperationModels

  test "snapshots configured legacy pairs but leaves fresh and explicitly configured selections alone" do
    for configured <- [true, false] do
      prefix = "operation_models_#{configured}"
      Repo.query!("CREATE SCHEMA #{prefix}")

      Repo.query!(
        "CREATE TABLE #{prefix}.system_configs (key text UNIQUE, value text, inserted_at timestamp, updated_at timestamp)"
      )

      Repo.query!(
        "INSERT INTO #{prefix}.system_configs (key, value) VALUES ('global.small_model.model', 'keep-me')"
      )

      if configured do
        Repo.query!(
          "INSERT INTO #{prefix}.system_configs (key, value) VALUES ('llm.credential_id', '12'), ('llm.model', 'legacy-model'), ('llm.temperature', '0.4')"
        )
      end

      assert :ok =
               Ecto.Migrator.up(Repo, 20_261_031_132_000, SnapshotOperationModels,
                 prefix: prefix,
                 log: false,
                 migration_lock: false
               )

      assert [["keep-me"]] =
               Repo.query!(
                 "SELECT value FROM #{prefix}.system_configs WHERE key = 'global.small_model.model'"
               ).rows

      assert [[count]] =
               Repo.query!(
                 "SELECT count(*) FROM #{prefix}.system_configs WHERE key LIKE 'rag.translation.%'"
               ).rows

      assert count == if(configured, do: 4, else: 0)

      if configured do
        assert [["12"], ["legacy-model"], ["0.4"], ["0.9"]] =
                 Repo.query!(
                   "SELECT value FROM #{prefix}.system_configs WHERE key LIKE 'rag.translation.%' ORDER BY key"
                 ).rows
      end
    end
  end
end
