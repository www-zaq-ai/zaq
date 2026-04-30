defmodule Zaq.Agent.ConfiguredAgentTest do
  use Zaq.DataCase, async: true

  import Zaq.SystemConfigFixtures

  alias Zaq.Agent.ConfiguredAgent
  alias Zaq.Repo

  describe "idle_time_seconds and memory_context_max_size" do
    test "changeset accepts positive integer for idle_time_seconds" do
      changeset = ConfiguredAgent.changeset(%ConfiguredAgent{}, %{idle_time_seconds: 3600})
      assert changeset.changes[:idle_time_seconds] == 3600
    end

    test "changeset accepts positive integer for memory_context_max_size" do
      changeset = ConfiguredAgent.changeset(%ConfiguredAgent{}, %{memory_context_max_size: 2000})
      assert changeset.changes[:memory_context_max_size] == 2000
    end

    test "changeset accepts nil for both fields" do
      changeset =
        ConfiguredAgent.changeset(%ConfiguredAgent{}, %{
          idle_time_seconds: nil,
          memory_context_max_size: nil
        })

      refute Keyword.has_key?(changeset.errors, :idle_time_seconds)
      refute Keyword.has_key?(changeset.errors, :memory_context_max_size)
    end

    test "changeset rejects zero idle_time_seconds" do
      changeset = ConfiguredAgent.changeset(%ConfiguredAgent{}, %{idle_time_seconds: 0})
      assert "must be greater than 0" in errors_on(changeset).idle_time_seconds
    end

    test "changeset rejects negative idle_time_seconds" do
      changeset = ConfiguredAgent.changeset(%ConfiguredAgent{}, %{idle_time_seconds: -1})
      assert "must be greater than 0" in errors_on(changeset).idle_time_seconds
    end

    test "changeset rejects zero memory_context_max_size" do
      changeset = ConfiguredAgent.changeset(%ConfiguredAgent{}, %{memory_context_max_size: 0})
      assert "must be greater than 0" in errors_on(changeset).memory_context_max_size
    end

    test "changeset rejects negative memory_context_max_size" do
      changeset = ConfiguredAgent.changeset(%ConfiguredAgent{}, %{memory_context_max_size: -5})
      assert "must be greater than 0" in errors_on(changeset).memory_context_max_size
    end
  end

  test "changeset accepts valid attributes" do
    credential =
      ai_credential_fixture(%{
        name:
          "Configured Agent Required Credential #{System.unique_integer([:positive, :monotonic])}",
        provider: "openai"
      })

    attrs = %{
      name: "Configured Agent #{System.unique_integer([:positive])}",
      description: "desc",
      job: "You are a helper",
      model: "gpt-4.1-mini",
      credential_id: credential.id,
      strategy: "react",
      enabled_tool_keys: ["files.read_file"],
      conversation_enabled: true,
      active: true,
      advanced_options: %{"temperature" => 0.2}
    }

    changeset = ConfiguredAgent.changeset(%ConfiguredAgent{}, attrs)
    assert changeset.valid?
  end

  test "changeset validates required fields and strategy" do
    changeset = ConfiguredAgent.changeset(%ConfiguredAgent{}, %{})

    refute changeset.valid?

    assert %{name: ["can't be blank"], job: ["can't be blank"], model: ["can't be blank"]} =
             errors_on(changeset)

    credential =
      ai_credential_fixture(%{
        name:
          "Configured Agent Strategy Credential #{System.unique_integer([:positive, :monotonic])}",
        provider: "openai"
      })

    invalid_strategy_changeset =
      ConfiguredAgent.changeset(%ConfiguredAgent{}, %{
        name: "Agent #{System.unique_integer([:positive])}",
        job: "do thing",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "invalid"
      })

    refute invalid_strategy_changeset.valid?
    assert "is invalid" in errors_on(invalid_strategy_changeset).strategy
  end

  test "changeset rejects unknown tool keys" do
    credential =
      ai_credential_fixture(%{
        name:
          "Configured Agent Tool Credential #{System.unique_integer([:positive, :monotonic])}",
        provider: "openai"
      })

    changeset =
      ConfiguredAgent.changeset(%ConfiguredAgent{}, %{
        name: "Agent #{System.unique_integer([:positive])}",
        job: "do thing",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: ["files.read_file", "files.unknown", "files.unknown"]
      })

    refute changeset.valid?
    assert "contains unknown tools: files.unknown" in errors_on(changeset).enabled_tool_keys
  end

  test "changeset normalizes enabled_mcp_endpoint_ids" do
    credential =
      ai_credential_fixture(%{
        name: "Configured Agent MCP Credential #{System.unique_integer([:positive, :monotonic])}",
        provider: "openai"
      })

    changeset =
      ConfiguredAgent.changeset(%ConfiguredAgent{}, %{
        name: "Agent #{System.unique_integer([:positive])}",
        job: "do thing",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_mcp_endpoint_ids: [1, 2, 1]
      })

    assert changeset.valid?
    assert Ecto.Changeset.get_field(changeset, :enabled_mcp_endpoint_ids) == [1, 2]
  end

  test "database constraints are surfaced by the changeset" do
    credential =
      ai_credential_fixture(%{
        name:
          "Configured Agent Constraint Credential #{System.unique_integer([:positive, :monotonic])}",
        provider: "openai"
      })

    name = "Unique Agent #{System.unique_integer([:positive])}"

    {:ok, _} =
      %ConfiguredAgent{}
      |> ConfiguredAgent.changeset(%{
        name: name,
        job: "job",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react"
      })
      |> Repo.insert()

    {:error, duplicate_changeset} =
      %ConfiguredAgent{}
      |> ConfiguredAgent.changeset(%{
        name: name,
        job: "other job",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react"
      })
      |> Repo.insert()

    assert "has already been taken" in errors_on(duplicate_changeset).name

    {:error, fk_changeset} =
      %ConfiguredAgent{}
      |> ConfiguredAgent.changeset(%{
        name: "FK Agent #{System.unique_integer([:positive])}",
        job: "job",
        model: "gpt-4.1-mini",
        credential_id: -1,
        strategy: "react"
      })
      |> Repo.insert()

    assert "does not exist" in errors_on(fk_changeset).credential_id
  end
end
