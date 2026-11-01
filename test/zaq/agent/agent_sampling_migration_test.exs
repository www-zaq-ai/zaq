unless Code.ensure_loaded?(Zaq.Repo.Migrations.AddAgentSampling) do
  Code.require_file(
    "../../../priv/repo/migrations/20261031131000_add_agent_sampling.exs",
    __DIR__
  )
end

defmodule Zaq.Agent.AgentSamplingMigrationTest do
  use Zaq.DataCase, async: false

  alias Zaq.Repo.Migrations.AddAgentSampling

  use ExUnitProperties

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

  property "normalizes legacy values independently without discarding unrelated options" do
    Repo.query!("CREATE SCHEMA #{@prefix}")
    Repo.query!("CREATE TABLE #{@prefix}.system_configs (key text, value text)")

    Repo.query!(
      "CREATE TABLE #{@prefix}.configured_agents (id serial, active boolean DEFAULT false, advanced_options jsonb)"
    )

    Repo.query!(
      "INSERT INTO #{@prefix}.system_configs VALUES ('llm.temperature', '0.4'), ('llm.top_p', '0.7')"
    )

    check all(temperature <- integer(0..200), top_p <- integer(1..100), max_runs: 10) do
      Repo.query!("TRUNCATE #{@prefix}.configured_agents")
      valid_temperature = temperature / 100
      valid_top_p = top_p / 100

      invalid = [
        nil,
        true,
        false,
        "",
        "auto",
        "0.5suffix",
        "NaN",
        "Infinity",
        "-Infinity",
        "1e999999",
        "-1e999999",
        [],
        %{},
        -1,
        3
      ]

      cases =
        [
          {%{}, [0.4, 0.7]},
          {%{"temperature" => valid_temperature, "top_p" => valid_top_p},
           [valid_temperature, valid_top_p]},
          {%{"temperature" => to_string(valid_temperature), "top_p" => to_string(valid_top_p)},
           [valid_temperature, valid_top_p]},
          {%{"temperature" => 2, "top_p" => 1}, [2.0, 1.0]},
          {%{"temperature" => 0, "top_p" => 0}, [0.0, 0.9]}
        ] ++
          Enum.flat_map(invalid, fn value ->
            [
              {%{"temperature" => value, "top_p" => valid_top_p}, [0.0, valid_top_p]},
              {%{"temperature" => valid_temperature, "top_p" => value}, [valid_temperature, 0.9]}
            ]
          end)

      for {options, _} <- cases do
        Repo.query!(
          "INSERT INTO #{@prefix}.configured_agents (advanced_options) VALUES ($1::jsonb)",
          [Map.put(options, "max_tokens", 40)]
        )
      end

      assert :ok = migrate(:up)
      assert :already_up = migrate(:up)

      assert Repo.query!(
               "SELECT temperature, top_p FROM #{@prefix}.configured_agents ORDER BY id"
             ).rows == Enum.map(cases, &elem(&1, 1))

      assert Enum.all?(
               Repo.query!("SELECT advanced_options FROM #{@prefix}.configured_agents").rows,
               &(&1 == [%{"max_tokens" => 40}])
             )

      assert :ok = migrate(:down)
    end
  end

  test "missing overrides normalize malformed global values to fixed defaults" do
    Repo.query!("CREATE SCHEMA #{@prefix}")
    Repo.query!("CREATE TABLE #{@prefix}.system_configs (key text, value text)")
    Repo.query!("CREATE TABLE #{@prefix}.configured_agents (advanced_options jsonb)")

    Repo.query!(
      "INSERT INTO #{@prefix}.system_configs VALUES ('llm.temperature', 'auto'), ('llm.top_p', 'NaN')"
    )

    Repo.query!("INSERT INTO #{@prefix}.configured_agents VALUES ('{}'), (null)")
    assert :ok = migrate(:up)

    assert [[0.0, 0.9], [0.0, 0.9]] =
             Repo.query!("SELECT temperature, top_p FROM #{@prefix}.configured_agents").rows
  end
end
