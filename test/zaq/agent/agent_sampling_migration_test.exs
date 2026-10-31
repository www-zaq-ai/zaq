unless Code.ensure_loaded?(Zaq.Repo.Migrations.AddAgentSampling) do
  Code.require_file(
    "../../../priv/repo/migrations/20261031131000_add_agent_sampling.exs",
    __DIR__
  )
end

defmodule Zaq.Agent.AgentSamplingMigrationTest do
  use Zaq.DataCase, async: false

  alias Zaq.Repo.Migrations.AddAgentSampling

  @prefix "agent_sampling_migration"
  @version 20_261_031_131_000

  test "snapshots effective legacy overrides, defaults new rows and preserves downgrade values" do
    Repo.query!("CREATE SCHEMA #{@prefix}")
    Repo.query!("CREATE TABLE #{@prefix}.system_configs (key text, value text)")

    Repo.query!(
      "INSERT INTO #{@prefix}.system_configs VALUES ('llm.temperature', '0.4'), ('llm.top_p', '0.7')"
    )

    Repo.query!("CREATE TABLE #{@prefix}.configured_agents (id serial, advanced_options jsonb)")

    Repo.query!(
      ~s(INSERT INTO #{@prefix}.configured_agents \(advanced_options\) VALUES \('{}'\), \('{"temperature":0.2,"max_tokens":40}'\), \('{"top_p":0.8}'\), \(null\))
    )

    assert :ok = migrate(:up)
    assert :already_up = migrate(:up)

    assert [[0.4, 0.7, %{}], [0.2, 0.7, %{"max_tokens" => 40}], [0.4, 0.8, %{}], [0.4, 0.7, %{}]] =
             Repo.query!(
               "SELECT temperature, top_p, advanced_options FROM #{@prefix}.configured_agents ORDER BY id"
             ).rows

    Repo.query!("INSERT INTO #{@prefix}.configured_agents (advanced_options) VALUES ('{}')")

    assert [[0.0, 0.9]] =
             Repo.query!(
               "SELECT temperature, top_p FROM #{@prefix}.configured_agents WHERE id = 5"
             ).rows

    assert :ok = migrate(:down)

    assert [[%{"temperature" => 0.2, "top_p" => 0.7, "max_tokens" => 40}]] =
             Repo.query!("SELECT advanced_options FROM #{@prefix}.configured_agents WHERE id = 2").rows
  end

  defp migrate(direction) do
    apply(Ecto.Migrator, direction, [
      Repo,
      @version,
      AddAgentSampling,
      [prefix: @prefix, log: false, migration_lock: false]
    ])
  end
end
