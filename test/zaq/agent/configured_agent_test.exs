defmodule Zaq.Agent.ConfiguredAgentTest do
  use Zaq.DataCase, async: true

  import Zaq.SystemConfigFixtures

  alias Zaq.Agent.ConfiguredAgent
  alias Zaq.Repo

  describe "runtime limit fields" do
    test "changeset accepts positive integer for max_iterations" do
      changeset = ConfiguredAgent.changeset(%ConfiguredAgent{}, %{max_iterations: 10})
      assert changeset.changes[:max_iterations] == 10
    end

    test "changeset accepts positive integer for idle_time_seconds" do
      changeset = ConfiguredAgent.changeset(%ConfiguredAgent{}, %{idle_time_seconds: 3600})
      assert changeset.changes[:idle_time_seconds] == 3600
    end

    test "changeset accepts positive integer for memory_context_max_size" do
      changeset = ConfiguredAgent.changeset(%ConfiguredAgent{}, %{memory_context_max_size: 2000})
      assert changeset.changes[:memory_context_max_size] == 2000
    end

    test "changeset accepts nil for runtime limit fields" do
      changeset =
        ConfiguredAgent.changeset(%ConfiguredAgent{}, %{
          max_iterations: nil,
          idle_time_seconds: nil,
          memory_context_max_size: nil
        })

      refute Keyword.has_key?(changeset.errors, :max_iterations)
      refute Keyword.has_key?(changeset.errors, :idle_time_seconds)
      refute Keyword.has_key?(changeset.errors, :memory_context_max_size)
    end

    test "changeset rejects zero max_iterations" do
      changeset = ConfiguredAgent.changeset(%ConfiguredAgent{}, %{max_iterations: 0})
      assert "must be greater than 0" in errors_on(changeset).max_iterations
    end

    test "changeset rejects negative max_iterations" do
      changeset = ConfiguredAgent.changeset(%ConfiguredAgent{}, %{max_iterations: -1})
      assert "must be greater than 0" in errors_on(changeset).max_iterations
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
      enabled_tool_keys: ["basic.sleep"],
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
        enabled_tool_keys: ["basic.sleep", "files.unknown", "files.unknown"]
      })

    refute changeset.valid?
    assert "contains unknown tools: files.unknown" in errors_on(changeset).enabled_tool_keys
  end

  test "changeset allows ghost keys already present in stored data" do
    credential =
      ai_credential_fixture(%{
        name: "Ghost Tool Credential #{System.unique_integer([:positive, :monotonic])}",
        provider: "openai"
      })

    existing_agent = %ConfiguredAgent{
      name: "Agent #{System.unique_integer([:positive])}",
      job: "do thing",
      model: "gpt-4.1-mini",
      credential_id: credential.id,
      strategy: "react",
      enabled_tool_keys: ["removed.ghost_tool"]
    }

    changeset =
      ConfiguredAgent.changeset(existing_agent, %{
        name: existing_agent.name,
        job: existing_agent.job,
        model: existing_agent.model,
        credential_id: existing_agent.credential_id,
        strategy: existing_agent.strategy,
        enabled_tool_keys: ["removed.ghost_tool"]
      })

    assert changeset.valid?
  end

  test "changeset allows removing a ghost key from stored data" do
    credential =
      ai_credential_fixture(%{
        name: "Ghost Remove Credential #{System.unique_integer([:positive, :monotonic])}",
        provider: "openai"
      })

    existing_agent = %ConfiguredAgent{
      name: "Agent #{System.unique_integer([:positive])}",
      job: "do thing",
      model: "gpt-4.1-mini",
      credential_id: credential.id,
      strategy: "react",
      enabled_tool_keys: ["removed.ghost_tool"]
    }

    changeset =
      ConfiguredAgent.changeset(existing_agent, %{
        name: existing_agent.name,
        job: existing_agent.job,
        model: existing_agent.model,
        credential_id: existing_agent.credential_id,
        strategy: existing_agent.strategy,
        enabled_tool_keys: []
      })

    assert changeset.valid?
    assert Ecto.Changeset.get_field(changeset, :enabled_tool_keys) == []
  end

  test "changeset still rejects brand-new unknown tool keys on a new agent" do
    credential =
      ai_credential_fixture(%{
        name: "New Unknown Credential #{System.unique_integer([:positive, :monotonic])}",
        provider: "openai"
      })

    changeset =
      ConfiguredAgent.changeset(%ConfiguredAgent{}, %{
        name: "Agent #{System.unique_integer([:positive])}",
        job: "do thing",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: ["files.brand_new_unknown"]
      })

    refute changeset.valid?

    assert "contains unknown tools: files.brand_new_unknown" in errors_on(changeset).enabled_tool_keys
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
