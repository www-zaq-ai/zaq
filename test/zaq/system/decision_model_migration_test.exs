unless Code.ensure_loaded?(Zaq.Repo.Migrations.MoveDecisionModelToGlobal) do
  Code.require_file(
    "../../../priv/repo/migrations/20261109113555_move_decision_model_to_global.exs",
    __DIR__
  )
end

defmodule Zaq.System.DecisionModelMigrationTest do
  use Zaq.DataCase, async: false

  alias Zaq.Repo.Migrations.MoveDecisionModelToGlobal

  test "migrates the legacy pair without overwriting any initialized global state" do
    cases = [
      {%{"credential_id" => "12", "model" => "jev"}, %{}},
      {%{"credential_id" => "", "model" => ""}, %{}},
      {%{"model" => "partial"}, %{}},
      {%{}, %{}},
      {%{"credential_id" => "12", "model" => "jev"}, %{"model" => "keep"}},
      {%{"credential_id" => "12", "model" => "jev"}, %{"credential_id" => ""}}
    ]

    for {{legacy, global}, index} <- Enum.with_index(cases) do
      prefix = "decision_migration_#{index}"
      Repo.query!("CREATE SCHEMA #{prefix}")

      Repo.query!(
        "CREATE TABLE #{prefix}.system_configs (key text UNIQUE, value text, inserted_at timestamp, updated_at timestamp)"
      )

      for {namespace, fields} <- [{"rag.decision", legacy}, {"global.decision_model", global}],
          {field, value} <- fields do
        Repo.query!("INSERT INTO #{prefix}.system_configs (key, value) VALUES ($1, $2)", [
          "#{namespace}.#{field}",
          value
        ])
      end

      opts = [prefix: prefix, log: false, migration_lock: false]
      version = 20_261_109_113_555
      assert :ok = Ecto.Migrator.up(Repo, version, MoveDecisionModelToGlobal, opts)
      expected = if map_size(global) > 0, do: global, else: legacy
      rows = read_pair(prefix)
      assert Map.new(rows, fn [key, value] -> {key, value} end) == expected
      assert :ok = Ecto.Migrator.down(Repo, version, MoveDecisionModelToGlobal, opts)
      assert :ok = Ecto.Migrator.up(Repo, version, MoveDecisionModelToGlobal, opts)
      assert read_pair(prefix) == rows
    end
  end

  defp read_pair(prefix) do
    Repo.query!(
      "SELECT replace(key, 'global.decision_model.', ''), value FROM #{prefix}.system_configs WHERE key LIKE 'global.decision_model.%' ORDER BY key"
    ).rows
  end
end
