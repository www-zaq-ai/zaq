defmodule Zaq.Agent.ConfiguredAgentTest do
  use Zaq.DataCase, async: true

  import Zaq.SystemConfigFixtures

  alias Zaq.Agent.ConfiguredAgent
  alias Zaq.Repo

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
