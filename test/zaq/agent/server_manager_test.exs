defmodule Zaq.Agent.ServerManagerTest do
  use Zaq.DataCase, async: false

  import Zaq.SystemConfigFixtures

  alias Zaq.Agent
  alias Zaq.Agent.ServerManager

  test "ensure_server returns a resolvable server reference" do
    credential =
      ai_credential_fixture(%{
        name: "OpenAI Credential #{System.unique_integer([:positive, :monotonic])}",
        provider: "openai",
        endpoint: "https://api.openai.com/v1",
        api_key: "x"
      })

    {:ok, configured_agent} =
      Agent.create_agent(%{
        name: "Server Ref Agent #{System.unique_integer([:positive])}",
        description: "",
        job: "You are a test agent",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        conversation_enabled: false,
        active: true,
        advanced_options: %{}
      })

    assert {:ok, server_ref} = ServerManager.ensure_server(configured_agent)
    refute is_binary(server_ref)

    assert {:via, Registry, {registry, key}} = server_ref
    assert registry == Jido.registry_name(Zaq.Agent.Jido)
    assert key == Agent.agent_server_id(configured_agent.id)
  end

  test "ensure_server supports catalog-only provider via openai runtime fallback" do
    credential =
      ai_credential_fixture(%{
        name: "Novita Credential #{System.unique_integer([:positive, :monotonic])}",
        provider: "novita_ai",
        endpoint: "https://api.novita.ai/openai/v1",
        api_key: "x"
      })

    {:ok, configured_agent} =
      Agent.create_agent(%{
        name: "Server Ref Novita Agent #{System.unique_integer([:positive])}",
        description: "",
        job: "You are a test agent",
        model: "deepseek/deepseek-r1-0528",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        conversation_enabled: false,
        active: true,
        advanced_options: %{}
      })

    assert {:ok, server_ref} = ServerManager.ensure_server(configured_agent)
    assert {:via, Registry, {_registry, _key}} = server_ref
  end
end
