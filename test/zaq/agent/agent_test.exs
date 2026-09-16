defmodule Zaq.AgentTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties

  import Zaq.SystemConfigFixtures

  alias Zaq.Agent
  alias Zaq.Agent.ConfiguredAgent
  alias Zaq.Agent.MCP
  alias Zaq.Agent.ProviderSpec
  alias Zaq.Agent.ServerManager
  alias Zaq.Channels.{ChannelConfig, RetrievalChannel}
  alias Zaq.Engine.IncomingMessageRouting
  alias Zaq.Engine.IncomingMessageRoutingRule
  alias Zaq.Repo
  alias Zaq.System, as: ZaqSystem
  alias Zaq.System.AIProviderCredential

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
    assert {:ok, found_by_name} = Agent.get_agent_by_name(created.name)
    assert found_by_name.id == created.id
    assert {:error, :agent_not_found} = Agent.get_agent_by_name("missing-agent-name")
    assert Agent.get_agent("not-an-id") == :error

    assert_raise ArgumentError, ~r/invalid id/, fn ->
      Agent.get_agent!("not-an-id")
    end

    assert {:ok, _agent} = Agent.get_active_agent(created.id)
    assert Agent.agent_server_id(created.id) == "configured_agent_#{created.id}"

    all = Agent.list_agents()
    assert Enum.any?(all, &(&1.id == created.id))
  end

  test "get_agents_by_ids/1 returns a map keyed by id, dropping unknown ids" do
    credential =
      ai_credential_fixture(%{
        name: "Agent Bulk Credential #{System.unique_integer([:positive, :monotonic])}",
        provider: "openai",
        sovereign: false
      })

    {:ok, agent} =
      Agent.create_agent(%{
        name: "Bulk Lookup Agent #{System.unique_integer([:positive])}",
        job: "job",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react"
      })

    result = Agent.get_agents_by_ids([agent.id, -1])

    assert map_size(result) == 1
    assert result[agent.id].name == agent.name
    assert result[agent.id].model == "gpt-4.1-mini"

    assert Agent.get_agents_by_ids([]) == %{}
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
    assert {:ok, _agent} = Agent.get_conversation_enabled_agent(active_conversation.id)
    assert {:error, :inactive_agent} = Agent.get_conversation_enabled_agent(inactive_agent.id)

    {:ok, bo_only_agent} =
      Agent.create_agent(%{
        name: "Agent BO Only #{System.unique_integer([:positive])}",
        job: "job",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        conversation_enabled: false,
        active: true,
        advanced_options: %{}
      })

    assert {:error, :conversation_disabled} =
             Agent.get_conversation_enabled_agent(bo_only_agent.id)

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

    {:ok, custom_agent} =
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

    assert {:ok,
            %{
              provider: :openai,
              id: "gpt-4.1-mini",
              base_url: "http://localhost:11434/v1"
            }} = ProviderSpec.build(custom_agent)

    assert {:ok, switched_agent} =
             Agent.update_agent(openai_agent, %{
               credential_id: custom_credential.id,
               model: "qwen2.5:7b"
             })

    assert switched_agent.credential.id == custom_credential.id

    assert {:ok,
            %{
              provider: :openai,
              id: "qwen2.5:7b",
              base_url: "http://localhost:11434/v1"
            }} = ProviderSpec.build(switched_agent)

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

  test "create_agent requires a credential when tools are selected" do
    name = "Agent Missing Credential #{System.unique_integer([:positive])}"

    assert {:error, changeset} =
             Agent.create_agent(%{
               name: name,
               job: "job",
               model: "gpt-4.1-mini",
               strategy: "react",
               enabled_tool_keys: ["general.encode_json"]
             })

    errors = errors_on(changeset)
    assert errors.credential_id == ["can't be blank"]
    refute Map.has_key?(errors, :enabled_tool_keys)
    assert Repo.get_by(ConfiguredAgent, name: name) == nil
  end

  test "create_agent rejects a nonexistent credential when tools are selected" do
    name = "Agent Unknown Credential #{System.unique_integer([:positive])}"
    assert Repo.get(AIProviderCredential, -1) == nil

    assert {:error, changeset} =
             Agent.create_agent(%{
               name: name,
               job: "job",
               model: "gpt-4.1-mini",
               credential_id: -1,
               strategy: "react",
               enabled_tool_keys: ["general.encode_json"]
             })

    errors = errors_on(changeset)
    assert errors.credential_id == ["does not exist"]
    refute Map.has_key?(errors, :enabled_tool_keys)
    assert Repo.get_by(ConfiguredAgent, name: name) == nil
  end

  test "runtime provider normalizes mixed-case catalog providers safely" do
    assert_raise ArgumentError, fn -> String.to_existing_atom("oPeNaI") end

    agent = %ConfiguredAgent{credential: %AIProviderCredential{provider: "oPeNaI"}}
    assert {:ok, :openai} = Agent.runtime_provider_for_agent(agent)

    assert_raise ArgumentError, fn -> String.to_existing_atom("oPeNaI") end
  end

  property "unknown runtime providers do not create atoms" do
    check all(suffix <- string(:alphanumeric, min_length: 1, max_length: 24)) do
      provider = "zaq_unknown_provider_#{suffix}"

      assert_raise ArgumentError, fn -> String.to_existing_atom(provider) end

      assert {:error, :provider_not_found} =
               Agent.runtime_provider_for_agent(%ConfiguredAgent{
                 credential: %AIProviderCredential{provider: provider}
               })

      assert_raise ArgumentError, fn -> String.to_existing_atom(provider) end
    end
  end

  test "delete_agent reports malformed topic routing rows defensively" do
    credential =
      ai_credential_fixture(%{
        name: "Delete Corrupt Credential #{System.unique_integer([:positive, :monotonic])}",
        provider: "openai"
      })

    {:ok, agent} =
      Agent.create_agent(%{
        name: "Delete Corrupt Agent #{System.unique_integer([:positive])}",
        job: "job",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: ["general.encode_json"],
        conversation_enabled: true
      })

    malformed_rule =
      %IncomingMessageRoutingRule{}
      |> Ecto.Changeset.change(%{
        topic_id: "INBOX",
        channel_config_id: nil,
        routing_mode: :agent,
        configured_agent_id: agent.id
      })
      |> Repo.insert!()

    assert {:error, changeset} = Agent.delete_agent(agent)

    assert errors_on(changeset).base == [
             "Agent is in use by:\n- incoming routing topic unknown:INBOX"
           ]

    assert Repo.get!(ConfiguredAgent, agent.id).id == agent.id
    assert Repo.get!(IncomingMessageRoutingRule, malformed_rule.id).id == malformed_rule.id
  end

  test "validates enabled_mcp_endpoint_ids and can list agents by endpoint assignment" do
    credential =
      ai_credential_fixture(%{
        name: "Agent MCP Credential #{System.unique_integer([:positive, :monotonic])}",
        provider: "openai"
      })

    {:ok, endpoint} =
      MCP.create_mcp_endpoint(%{
        name: "Agent MCP #{System.unique_integer([:positive])}",
        type: "remote",
        status: "enabled",
        timeout_ms: 5000,
        url: "http://localhost:8000/mcp"
      })

    {:ok, assigned} =
      Agent.create_agent(%{
        name: "Agent With MCP #{System.unique_integer([:positive])}",
        job: "job",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        enabled_mcp_endpoint_ids: [endpoint.id],
        conversation_enabled: false,
        active: true,
        advanced_options: %{}
      })

    {:ok, other} =
      Agent.create_agent(%{
        name: "Agent Without MCP #{System.unique_integer([:positive])}",
        job: "job",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        enabled_mcp_endpoint_ids: [],
        conversation_enabled: false,
        active: true,
        advanced_options: %{}
      })

    listed = Agent.list_agents_with_mcp_endpoint(endpoint.id)
    assert Enum.any?(listed, &(&1.id == assigned.id))
    refute Enum.any?(listed, &(&1.id == other.id))

    {:error, changeset} =
      Agent.create_agent(%{
        name: "Agent With Unknown MCP #{System.unique_integer([:positive])}",
        job: "job",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        enabled_mcp_endpoint_ids: [999_999_999],
        conversation_enabled: false,
        active: true,
        advanced_options: %{}
      })

    assert errors_on(changeset).enabled_mcp_endpoint_ids
           |> to_string()
           |> String.contains?("contains unknown MCP endpoint ids")
  end

  test "list_agents_with_skill returns only agents referencing the skill id" do
    credential =
      ai_credential_fixture(%{
        name: "Agent Skill Credential #{System.unique_integer([:positive, :monotonic])}",
        provider: "openai"
      })

    skill_id = System.unique_integer([:positive])

    {:ok, assigned} =
      Agent.create_agent(%{
        name: "Agent With Skill #{System.unique_integer([:positive])}",
        job: "job",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_skill_ids: [skill_id],
        conversation_enabled: false,
        active: true,
        advanced_options: %{}
      })

    {:ok, other} =
      Agent.create_agent(%{
        name: "Agent Without Skill #{System.unique_integer([:positive])}",
        job: "job",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_skill_ids: [],
        conversation_enabled: false,
        active: true,
        advanced_options: %{}
      })

    listed = Agent.list_agents_with_skill(skill_id)
    assert Enum.any?(listed, &(&1.id == assigned.id))
    refute Enum.any?(listed, &(&1.id == other.id))
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

  test "runtime provider returns provider_not_found without a custom endpoint" do
    credential = %AIProviderCredential{id: -1, provider: "elixir", endpoint: nil}

    changeset =
      Agent.change_agent(
        %ConfiguredAgent{credential_id: credential.id, credential: credential},
        %{
          name: "Provider Existing Atom Unknown #{System.unique_integer([:positive])}",
          job: "job",
          model: "gpt-4.1-mini",
          credential_id: credential.id,
          strategy: "react",
          enabled_tool_keys: [],
          conversation_enabled: false,
          active: true,
          advanced_options: %{}
        }
      )

    assert "selected provider cannot be used at runtime (provider_not_found)" in errors_on(
             changeset
           ).credential_id
  end

  test "delete_agent/1 blocks deletion when agent is referenced in routing config" do
    credential =
      ai_credential_fixture(%{
        name: "Delete Guard Credential #{System.unique_integer([:positive, :monotonic])}",
        provider: "openai"
      })

    {:ok, agent} =
      Agent.create_agent(%{
        name: "Delete Guard Agent #{System.unique_integer([:positive])}",
        job: "job",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        conversation_enabled: true,
        active: true,
        advanced_options: %{}
      })

    {:ok, mattermost_config} =
      ChannelConfig.upsert_by_provider("mattermost", %{
        name: "MM",
        kind: "retrieval",
        url: "https://mattermost.example.com",
        token: "tok",
        enabled: true,
        settings: %{}
      })

    {:ok, _provider_rule} =
      IncomingMessageRouting.upsert_rule(%{channel_config_id: mattermost_config.id}, %{
        routing_mode: :agent,
        configured_agent_id: agent.id
      })

    retrieval_channel =
      %RetrievalChannel{}
      |> RetrievalChannel.changeset(%{
        channel_config_id: mattermost_config.id,
        channel_id: "chan-1",
        channel_name: "General",
        team_id: "team-1",
        team_name: "Team",
        active: true
      })
      |> Repo.insert!()

    Repo.insert!(%IncomingMessageRoutingRule{
      channel_config_id: mattermost_config.id,
      retrieval_channel_id: retrieval_channel.id,
      routing_mode: :agent,
      configured_agent_id: agent.id
    })

    {:ok, _smtp_config} =
      ChannelConfig.upsert_by_provider("email:smtp", %{
        name: "SMTP",
        kind: "retrieval",
        enabled: true,
        settings: %{"relay" => "", "port" => "587", "transport_mode" => "starttls"}
      })

    {:ok, imap_config} =
      ChannelConfig.upsert_by_provider("email:imap", %{
        name: "IMAP",
        kind: "retrieval",
        enabled: true,
        url: "imap.example.com",
        token: "imap-token",
        settings: %{
          "imap" => %{
            "selected_mailboxes" => ["INBOX"]
          }
        }
      })

    {:ok, _mailbox_rule} =
      IncomingMessageRouting.upsert_rule(
        %{channel_config_id: imap_config.id, topic_id: "INBOX"},
        %{
          routing_mode: :agent,
          configured_agent_id: agent.id
        }
      )

    :ok = ZaqSystem.set_global_default_agent_id(agent.id)

    assert {:error, changeset} = Agent.delete_agent(agent)

    assert [message | _] = errors_on(changeset).base
    assert message =~ "Agent is in use by:\n"
    assert message =~ "- incoming routing channel rule"
    assert message =~ "- incoming routing provider"
    assert message =~ "- incoming routing topic email:imap:INBOX"
    assert message =~ "- incoming routing global default"
  end

  test "delete_agent/1 succeeds when agent is unreferenced" do
    credential =
      ai_credential_fixture(%{
        name: "Delete Free Credential #{System.unique_integer([:positive, :monotonic])}",
        provider: "openai"
      })

    {:ok, agent} =
      Agent.create_agent(%{
        name: "Delete Free Agent #{System.unique_integer([:positive])}",
        job: "job",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        conversation_enabled: true,
        active: true,
        advanced_options: %{}
      })

    assert {:ok, _deleted} = Agent.delete_agent(agent)
    assert Agent.get_agent(agent.id) == nil
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

  test "unknown model capability does not block tools on create, update, or change" do
    credential =
      ai_credential_fixture(%{
        name:
          "Agent Tool Validation Credential #{System.unique_integer([:positive, :monotonic])}",
        provider: "openai"
      })

    {:ok, created_with_unknown_model} =
      Agent.create_agent(%{
        name: "Tool Invalid Create #{System.unique_integer([:positive])}",
        job: "job",
        model: "not-a-real-model",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: ["general.encode_json"],
        conversation_enabled: false,
        active: true,
        advanced_options: %{}
      })

    assert created_with_unknown_model.enabled_tool_keys == ["general.encode_json"]

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

    {:ok, updated_agent} =
      Agent.update_agent(agent, %{
        model: "not-a-real-model",
        enabled_tool_keys: ["general.encode_json"]
      })

    assert updated_agent.enabled_tool_keys == ["general.encode_json"]

    changeset =
      Agent.change_agent(agent, %{
        model: "not-a-real-model",
        enabled_tool_keys: ["general.encode_json"]
      })

    assert changeset.valid?
  end

  test "confirmed unsupported model capability blocks configured tools" do
    credential =
      ai_credential_fixture(%{
        name:
          "Agent Unsupported Tools Credential #{System.unique_integer([:positive, :monotonic])}",
        provider: "novita_ai"
      })

    {:error, changeset} =
      Agent.create_agent(%{
        name: "Unsupported Tools Agent #{System.unique_integer([:positive])}",
        job: "job",
        model: "qwen/qwen3-4b-fp8",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: ["general.encode_json"],
        conversation_enabled: false,
        active: true,
        advanced_options: %{}
      })

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
    _ = drain_repo_query_sources([], 100)

    changeset =
      Agent.change_agent(agent, %{
        model: "not-a-real-model",
        enabled_tool_keys: ["general.encode_json"]
      })

    assert changeset.valid?

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
          if self() == test_pid, do: send(test_pid, {:repo_query, metadata[:source]})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  defp drain_repo_query_sources(acc \\ [], timeout \\ 0) do
    receive do
      {:repo_query, source} -> drain_repo_query_sources([source | acc], timeout)
    after
      timeout -> Enum.reverse(acc)
    end
  end
end
