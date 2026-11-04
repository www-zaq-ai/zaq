defmodule Zaq.UserPortal.ProvisionerTest do
  use Zaq.DataCase, async: false

  alias Zaq.Agent
  alias Zaq.Agent.Api, as: AgentApi
  alias Zaq.Engine.Api
  alias Zaq.Engine.IncomingMessageRouting
  alias Zaq.Event
  alias Zaq.System
  alias Zaq.UserPortal.Provisioner

  defmodule EngineRouter do
    def dispatch(%Event{} = event) do
      send(self(), {:engine_event, event})

      case event.next_hop.destination do
        :engine -> Api.handle_event(event, event.opts[:action], nil)
        :agent -> AgentApi.handle_event(event, event.opts[:action], nil)
      end
    end
  end

  defmodule UnavailableAgentRouter do
    def dispatch(%Event{next_hop: %{destination: :agent}} = event),
      do: %{event | response: {:error, {:service_unavailable, :agent}}}

    def dispatch(event), do: EngineRouter.dispatch(event)
  end

  defmodule UnavailableRoutingRouter do
    def dispatch(%Event{opts: [{:action, :upsert_incoming_message_routing_rules} | _]} = event),
      do: %{event | response: {:error, :routing_unavailable}}

    def dispatch(event), do: EngineRouter.dispatch(event)
  end

  defmodule FailedAgentCreationRouter do
    def dispatch(%Event{request: %{function: :create_agent}} = event),
      do: %{event | response: {:error, :agent_creation_failed}}

    def dispatch(event), do: EngineRouter.dispatch(event)
  end

  defmodule UnavailableEngineRouter do
    def dispatch(%Event{} = event),
      do: %{event | response: {:error, {:service_unavailable, :engine}}}
  end

  describe "provision_with_key/1" do
    test "routes secret-bearing create and update mutations through Engine" do
      opts = [node_router_module: EngineRouter]

      assert {:ok, credential} =
               Provisioner.provision_with_key(%{litellm_api_key: "sk-routed-create"}, opts)

      assert_received {:engine_event, create_event}
      assert create_event.next_hop.destination == :engine
      assert create_event.opts[:action] == :system_config_create_ai_provider_credential
      assert create_event.opts[:confidential] == true
      assert create_event.actor == %{kind: :system, subject: "user-portal-provisioner"}

      assert {:ok, updated} =
               Provisioner.provision_with_key(%{litellm_api_key: "sk-routed-update"}, opts)

      assert updated.id == credential.id

      assert_received {:engine_event,
                       %Event{opts: [{:action, :system_config_update_ai_provider_credential} | _]} =
                         update_event}

      assert update_event.opts[:action] == :system_config_update_ai_provider_credential
      assert update_event.opts[:confidential] == true
    end

    test "propagates Engine unavailability without local persistence" do
      assert Provisioner.provision_with_key(
               %{litellm_api_key: "sk-unavailable"},
               node_router_module: UnavailableEngineRouter
             ) == {:error, {:service_unavailable, :engine}}

      assert System.get_ai_provider_credential_by_name(Provisioner.credential_name()) == nil
    end

    test "creates a new ZAQ Router credential when none exists" do
      assert {:ok, credential} = Provisioner.provision_with_key(%{litellm_api_key: "sk-new"})
      credential = System.get_ai_provider_credential!(credential.id)

      assert credential.name == "ZAQ Router"
      assert credential.provider == "zaq_router"
      assert credential.api_key == "sk-new"
    end

    test "updates an existing ZAQ Router credential" do
      assert {:ok, credential} = Provisioner.provision_with_key(%{litellm_api_key: "sk-existing"})

      assert {:ok, updated} = Provisioner.provision_with_key(%{litellm_api_key: "sk-updated"})
      updated = System.get_ai_provider_credential!(updated.id)

      assert updated.id == credential.id
      assert updated.api_key == "sk-updated"
    end

    test "creates a knowledge agent and global routing, and wires embedding and image configs" do
      assert {:ok, credential} = Provisioner.provision_with_key(%{litellm_api_key: "sk-config"})

      assert {:ok, agent} = Agent.get_agent_by_name("ZAQ Assistant")
      assert agent.credential_id == credential.id
      assert agent.model == "openai/gpt-oss-120b"
      assert agent.active
      assert agent.conversation_enabled
      assert agent.job == "Help users answer questions using the company knowledge base."

      assert Enum.sort(agent.enabled_tool_keys) ==
               ["answering.get_knowledge_base_chunks", "answering.search_knowledge_base"]

      assert IncomingMessageRouting.get_rule(%{}).configured_agent_id == agent.id

      assert System.get_embedding_config().credential_id == credential.id
      assert System.get_embedding_config().model == "nvidia/llama-nemotron-embed-vl-1b-v2"
      assert System.get_embedding_config().dimension == 2048

      assert System.get_image_to_text_config().credential_id == credential.id

      assert System.get_image_to_text_config().model ==
               "nvidia/nemotron-nano-12b-v2-vl"
    end

    test "does not overwrite existing configs on second call" do
      existing_embedding =
        Zaq.SystemConfigFixtures.seed_embedding_config(%{model: "existing-embed"})

      existing_image =
        Zaq.SystemConfigFixtures.seed_image_to_text_config(%{model: "existing-image"})

      assert {:ok, _credential} = Provisioner.provision_with_key(%{litellm_api_key: "sk-keep"})

      assert System.get_embedding_config().credential_id == existing_embedding.id
      assert System.get_embedding_config().model == "existing-embed"
      assert System.get_image_to_text_config().credential_id == existing_image.id
      assert System.get_image_to_text_config().model == "existing-image"
    end

    test "retries reuse the agent and preserve user customizations" do
      assert {:ok, credential} = Provisioner.provision_with_key(%{litellm_api_key: "sk-first"})
      assert {:ok, agent} = Agent.get_agent_by_name("ZAQ Assistant")
      assert {:ok, _} = Agent.update_agent(agent, %{job: "Custom job", enabled_tool_keys: []})

      assert {:ok, updated} = Provisioner.provision_with_key(%{litellm_api_key: "sk-retry"})
      assert updated.id == credential.id
      assert {:ok, same} = Agent.get_agent_by_name("ZAQ Assistant")
      assert same.id == agent.id
      assert same.job == "Custom job"
      assert same.enabled_tool_keys == []
      assert IncomingMessageRouting.get_rule(%{}).configured_agent_id == agent.id
    end

    test "preserves an explicit global none rule" do
      assert {:ok, rule} = IncomingMessageRouting.upsert_rule(%{}, %{routing_mode: "none"})
      assert {:ok, _} = Provisioner.provision_with_key(%{litellm_api_key: "sk-none"})
      assert IncomingMessageRouting.get_rule(%{}).id == rule.id
      assert IncomingMessageRouting.get_rule(%{}).routing_mode == :none
    end

    test "preserves an existing global agent assignment" do
      credential = Zaq.SystemConfigFixtures.ai_credential_fixture()

      assert {:ok, agent} =
               Agent.create_agent(%{
                 name: "Existing agent",
                 job: "Existing job",
                 model: "test-model",
                 credential_id: credential.id,
                 conversation_enabled: true
               })

      assert {:ok, rule} =
               IncomingMessageRouting.upsert_rule(%{}, %{
                 routing_mode: "agent",
                 configured_agent_id: agent.id
               })

      assert {:ok, _} = Provisioner.provision_with_key(%{litellm_api_key: "sk-existing-rule"})
      assert IncomingMessageRouting.get_rule(%{}).id == rule.id
      assert IncomingMessageRouting.get_rule(%{}).configured_agent_id == agent.id
    end

    test "propagates agent service failure and can recover on retry" do
      assert {:error, {:service_unavailable, :agent}} =
               Provisioner.provision_with_key(%{litellm_api_key: "sk-agent-unavailable"},
                 node_router_module: UnavailableAgentRouter
               )

      assert {:error, :agent_not_found} = Agent.get_agent_by_name("ZAQ Assistant")
      assert is_nil(IncomingMessageRouting.get_rule(%{}))
      assert {:ok, _} = Provisioner.provision_with_key(%{litellm_api_key: "sk-recovered"})
      assert {:ok, _agent} = Agent.get_agent_by_name("ZAQ Assistant")
    end

    test "propagates routing failure and retries without duplicating the agent" do
      assert {:error, :routing_unavailable} =
               Provisioner.provision_with_key(%{litellm_api_key: "sk-routing-unavailable"},
                 node_router_module: UnavailableRoutingRouter
               )

      assert {:ok, agent} = Agent.get_agent_by_name("ZAQ Assistant")
      assert is_nil(IncomingMessageRouting.get_rule(%{}))
      assert {:ok, _} = Provisioner.provision_with_key(%{litellm_api_key: "sk-recovered"})
      assert {:ok, same} = Agent.get_agent_by_name("ZAQ Assistant")
      assert same.id == agent.id
      assert IncomingMessageRouting.get_rule(%{}).configured_agent_id == agent.id
    end

    test "propagates agent creation errors without creating a routing rule" do
      assert {:error, :agent_creation_failed} =
               Provisioner.provision_with_key(%{litellm_api_key: "sk-creation-failure"},
                 node_router_module: FailedAgentCreationRouter
               )

      assert {:error, :agent_not_found} = Agent.get_agent_by_name("ZAQ Assistant")
      assert is_nil(IncomingMessageRouting.get_rule(%{}))
    end
  end

  describe "ensure_offline_credential/0" do
    test "creates a keyless ZAQ Router credential without wiring model configs" do
      assert {:ok, credential} = Provisioner.ensure_offline_credential()
      credential = System.get_ai_provider_credential!(credential.id)

      assert credential.name == "ZAQ Router"
      assert credential.provider == "zaq_router"
      assert is_nil(credential.api_key)

      # Provider is listed, but not set as the active model configuration.
      assert {:error, :agent_not_found} = Agent.get_agent_by_name("ZAQ Assistant")
      assert is_nil(IncomingMessageRouting.get_rule(%{}))
      assert is_nil(System.get_embedding_config().credential_id)
      assert is_nil(System.get_image_to_text_config().credential_id)
    end

    test "does not overwrite an existing credential or its key" do
      assert {:ok, existing} = Provisioner.provision_with_key(%{litellm_api_key: "sk-keep"})

      assert {:ok, same} = Provisioner.ensure_offline_credential()

      assert same.id == existing.id
      assert System.get_ai_provider_credential!(same.id).api_key == "sk-keep"
    end
  end
end
