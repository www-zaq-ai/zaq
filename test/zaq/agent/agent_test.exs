defmodule Zaq.AgentTest do
  use Zaq.DataCase, async: true

  import Zaq.SystemConfigFixtures

  alias Zaq.Agent
  alias Zaq.Agent.ConfiguredAgent

  test "list, get, and id helpers" do
    credential =
      ai_credential_fixture(%{
        name: "Agent List Credential #{System.unique_integer([:positive, :monotonic])}",
        provider: "openai",
        sovereign: false
      })

    {:ok, created} =
      Agent.create_agent(%{
        name: "Agent Context #{System.unique_integer([:positive])}",
        description: "desc",
        job: "job",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        conversation_enabled: true,
        active: true,
        advanced_options: %{}
      })

    assert created.id == Agent.get_agent!(created.id).id
    assert created.id == Agent.get_agent!(to_string(created.id)).id
    assert created.id == Agent.get_agent(created.id).id
    assert created.id == Agent.get_agent(to_string(created.id)).id
    assert Agent.get_agent("not-an-id") == :error

    assert_raise ArgumentError, ~r/invalid id/, fn ->
      Agent.get_agent!("not-an-id")
    end

    assert {:ok, _agent} = Agent.get_active_agent(created.id)
    assert Agent.agent_server_id(created.id) == "configured_agent_#{created.id}"

    all = Agent.list_agents()
    assert Enum.any?(all, &(&1.id == created.id))
  end

  test "active and conversation-enabled filtering" do
    credential =
      ai_credential_fixture(%{
        name: "Agent Active Credential #{System.unique_integer([:positive, :monotonic])}",
        provider: "openai",
        sovereign: false
      })

    {:ok, active_conversation} =
      Agent.create_agent(%{
        name: "Agent Active Conversation #{System.unique_integer([:positive])}",
        job: "job",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        conversation_enabled: true,
        active: true,
        advanced_options: %{}
      })

    {:ok, inactive_agent} =
      Agent.create_agent(%{
        name: "Agent Inactive #{System.unique_integer([:positive])}",
        job: "job",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        conversation_enabled: true,
        active: false,
        advanced_options: %{}
      })

    assert Enum.any?(Agent.list_active_agents(), &(&1.id == active_conversation.id))
    refute Enum.any?(Agent.list_active_agents(), &(&1.id == inactive_agent.id))

    assert Enum.any?(Agent.list_conversation_enabled_agents(), &(&1.id == active_conversation.id))
    refute Enum.any?(Agent.list_conversation_enabled_agents(), &(&1.id == inactive_agent.id))

    assert {:error, :inactive_agent} = Agent.get_active_agent(inactive_agent.id)
    assert {:error, :agent_not_found} = Agent.get_active_agent(9_999_999)

    {disabled_conversation, _} =
      Agent.filter_agents(%{"conversation_enabled" => "disabled"}, page: 1, per_page: 50)

    assert Enum.all?(disabled_conversation, &(&1.conversation_enabled == false))

    {inactive_only, _} = Agent.filter_agents(%{"active" => "inactive"}, page: 1, per_page: 50)
    assert Enum.all?(inactive_only, &(&1.active == false))
  end

  test "filter_agents applies all filter dimensions and paging" do
    sovereign_credential =
      ai_credential_fixture(%{
        name: "Agent Sovereign Credential #{System.unique_integer([:positive, :monotonic])}",
        provider: "openai",
        sovereign: true
      })

    standard_credential =
      ai_credential_fixture(%{
        name: "Agent Standard Credential #{System.unique_integer([:positive, :monotonic])}",
        provider: "openai",
        sovereign: false
      })

    unique = System.unique_integer([:positive])

    {:ok, keep} =
      Agent.create_agent(%{
        name: "Alpha 100% Keep #{unique}",
        job: "job",
        model: "gpt-4.1-mini",
        credential_id: sovereign_credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        conversation_enabled: true,
        active: true,
        advanced_options: %{}
      })

    {:ok, _other_1} =
      Agent.create_agent(%{
        name: "Beta Drop #{unique}",
        job: "job",
        model: "gpt-4o-mini",
        credential_id: standard_credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        conversation_enabled: false,
        active: true,
        advanced_options: %{}
      })

    {:ok, _other_2} =
      Agent.create_agent(%{
        name: "Gamma Drop #{unique}",
        job: "job",
        model: "gpt-4.1-mini",
        credential_id: sovereign_credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        conversation_enabled: true,
        active: false,
        advanced_options: %{}
      })

    filters = %{
      "name" => "100% Keep",
      "model" => "4.1",
      "conversation_enabled" => "enabled",
      "active" => "active",
      "sovereign" => "sovereign"
    }

    {agents, total} = Agent.filter_agents(filters, page: 1, per_page: 20)

    assert total == 1
    assert Enum.map(agents, & &1.id) == [keep.id]

    {paged, paged_total} = Agent.filter_agents(%{}, page: 2, per_page: 1)
    assert paged_total >= 3
    assert length(paged) == 1

    {non_sovereign, _} =
      Agent.filter_agents(%{"sovereign" => "non_sovereign"}, page: 1, per_page: 50)

    assert Enum.all?(non_sovereign, &(&1.credential && &1.credential.sovereign == false))
  end

  test "provider resolution and runtime provider resolution" do
    openai_credential =
      ai_credential_fixture(%{
        name:
          "Agent Provider OpenAI Credential #{System.unique_integer([:positive, :monotonic])}",
        provider: "openai"
      })

    {:ok, openai_agent} =
      Agent.create_agent(%{
        name: "Provider OpenAI #{System.unique_integer([:positive])}",
        job: "job",
        model: "gpt-4.1-mini",
        credential_id: openai_credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        conversation_enabled: false,
        active: true,
        advanced_options: %{}
      })

    assert Agent.provider_for_agent(openai_agent) == "openai"
    assert {:ok, :openai} = Agent.runtime_provider_for_agent(openai_agent)

    custom_credential =
      ai_credential_fixture(%{
        name:
          "Agent Provider Missing Credential #{System.unique_integer([:positive, :monotonic])}",
        provider: "provider_not_found_zaq"
      })

    {:error, changeset} =
      Agent.create_agent(%{
        name: "Provider Missing #{System.unique_integer([:positive])}",
        job: "job",
        model: "gpt-4.1-mini",
        credential_id: custom_credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        conversation_enabled: false,
        active: true,
        advanced_options: %{}
      })

    assert "selected provider cannot be used at runtime (provider_not_found)" in errors_on(
             changeset
           ).credential_id

    assert Agent.provider_for_agent(%ConfiguredAgent{}) == nil
    assert {:error, :invalid_provider} = Agent.runtime_provider_for_agent(%ConfiguredAgent{})

    assert Agent.provider_for_agent(%ConfiguredAgent{credential_id: -1}) == nil
    assert Agent.get_agent(:invalid_id_type) == :error
  end

  test "runtime provider resolves catalog-only providers to openai" do
    credential =
      ai_credential_fixture(%{
        name:
          "Agent Provider Novita Credential #{System.unique_integer([:positive, :monotonic])}",
        provider: "novita_ai"
      })

    {:ok, agent} =
      Agent.create_agent(%{
        name: "Provider Novita #{System.unique_integer([:positive])}",
        job: "job",
        model: "deepseek/deepseek-r1-0528",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        conversation_enabled: false,
        active: true,
        advanced_options: %{}
      })

    assert Agent.provider_for_agent(%ConfiguredAgent{credential_id: credential.id}) == "novita_ai"
    assert {:ok, :openai} = Agent.runtime_provider_for_agent(agent)
  end

  test "runtime provider returns provider_not_supported for known unsupported runtime" do
    credential =
      ai_credential_fixture(%{
        name:
          "Agent Provider Unsupported Credential #{System.unique_integer([:positive, :monotonic])}",
        provider: "perplexity"
      })

    {:error, changeset} =
      Agent.create_agent(%{
        name: "Provider Unsupported #{System.unique_integer([:positive])}",
        job: "job",
        model: "sonar-pro",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        conversation_enabled: false,
        active: true,
        advanced_options: %{}
      })

    assert "selected provider cannot be used at runtime (provider_not_supported)" in errors_on(
             changeset
           ).credential_id
  end

  test "runtime provider returns provider_not_found for existing but unknown atom provider" do
    credential =
      ai_credential_fixture(%{
        name:
          "Agent Provider Existing Atom Unknown Credential #{System.unique_integer([:positive, :monotonic])}",
        provider: "elixir"
      })

    {:error, changeset} =
      Agent.create_agent(%{
        name: "Provider Existing Atom Unknown #{System.unique_integer([:positive])}",
        job: "job",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        conversation_enabled: false,
        active: true,
        advanced_options: %{}
      })

    assert "selected provider cannot be used at runtime (provider_not_found)" in errors_on(
             changeset
           ).credential_id
  end

  test "tool capability validation is skipped when no tools are selected" do
    credential =
      ai_credential_fixture(%{
        name: "Agent No Tools Credential #{System.unique_integer([:positive, :monotonic])}",
        provider: "openai"
      })

    assert {:ok, _agent} =
             Agent.create_agent(%{
               name: "No Tools Agent #{System.unique_integer([:positive])}",
               job: "job",
               model: "not-a-real-model",
               credential_id: credential.id,
               strategy: "react",
               enabled_tool_keys: [],
               conversation_enabled: false,
               active: true,
               advanced_options: %{}
             })
  end

  test "tool capability validation for create, update and change" do
    credential =
      ai_credential_fixture(%{
        name:
          "Agent Tool Validation Credential #{System.unique_integer([:positive, :monotonic])}",
        provider: "openai"
      })

    {:error, create_changeset} =
      Agent.create_agent(%{
        name: "Tool Invalid Create #{System.unique_integer([:positive])}",
        job: "job",
        model: "not-a-real-model",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: ["files.read_file"],
        conversation_enabled: false,
        active: true,
        advanced_options: %{}
      })

    assert "selected model does not support tool calling" in errors_on(create_changeset).enabled_tool_keys

    {:ok, agent} =
      Agent.create_agent(%{
        name: "Tool Update Base #{System.unique_integer([:positive])}",
        job: "job",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        conversation_enabled: false,
        active: true,
        advanced_options: %{}
      })

    {:error, update_changeset} =
      Agent.update_agent(agent, %{
        model: "not-a-real-model",
        enabled_tool_keys: ["files.read_file"]
      })

    assert "selected model does not support tool calling" in errors_on(update_changeset).enabled_tool_keys

    changeset =
      Agent.change_agent(agent, %{
        model: "not-a-real-model",
        enabled_tool_keys: ["files.read_file"]
      })

    refute changeset.valid?

    assert "selected model does not support tool calling" in errors_on(changeset).enabled_tool_keys
  end

  test "change_agent reuses preloaded credential without extra lookup query" do
    credential =
      ai_credential_fixture(%{
        name: "Agent Query Reuse Credential #{System.unique_integer([:positive, :monotonic])}",
        provider: "openai"
      })

    {:ok, agent} =
      Agent.create_agent(%{
        name: "Query Reuse Agent #{System.unique_integer([:positive])}",
        job: "job",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        conversation_enabled: false,
        active: true,
        advanced_options: %{}
      })

    attach_repo_query_telemetry(self())
    _ = drain_repo_query_sources()

    changeset =
      Agent.change_agent(agent, %{
        model: "not-a-real-model",
        enabled_tool_keys: ["files.read_file"]
      })

    refute changeset.valid?

    assert "selected model does not support tool calling" in errors_on(changeset).enabled_tool_keys

    sources = drain_repo_query_sources()
    refute Enum.any?(sources, &(&1 == "ai_provider_credentials"))
  end

  test "delete_agent removes the record" do
    credential =
      ai_credential_fixture(%{
        name: "Agent Delete Credential #{System.unique_integer([:positive, :monotonic])}",
        provider: "openai"
      })

    {:ok, agent} =
      Agent.create_agent(%{
        name: "Delete Agent #{System.unique_integer([:positive])}",
        job: "job",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        conversation_enabled: false,
        active: true,
        advanced_options: %{}
      })

    assert {:ok, _deleted} = Agent.delete_agent(agent)
    assert Agent.get_agent(agent.id) == nil
  end

  defp attach_repo_query_telemetry(test_pid) do
    ref = make_ref()
    handler_id = {__MODULE__, :repo_query, ref}

    :ok =
      :telemetry.attach(
        handler_id,
        [:zaq, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:repo_query, metadata[:source]})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  defp drain_repo_query_sources(acc \\ []) do
    receive do
      {:repo_query, source} -> drain_repo_query_sources([source | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
