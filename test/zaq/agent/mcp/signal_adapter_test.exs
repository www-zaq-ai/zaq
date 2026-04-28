defmodule Zaq.Agent.MCP.SignalAdapterTest do
  use Zaq.DataCase, async: false

  import Zaq.SystemConfigFixtures

  alias Zaq.Agent
  alias Zaq.Agent.ConfiguredAgent
  alias Zaq.Agent.MCP
  alias Zaq.Agent.MCP.Runtime
  alias Zaq.Agent.MCP.SignalAdapter
  alias Zaq.Agent.ServerManager

  defp configured_agent_fixture do
    credential =
      ai_credential_fixture(%{
        name: "Signal Adapter Credential #{System.unique_integer([:positive, :monotonic])}",
        provider: "openai",
        endpoint: "https://api.openai.com/v1",
        api_key: "x"
      })

    {:ok, configured_agent} =
      Agent.create_agent(%{
        name: "Signal Adapter Agent #{System.unique_integer([:positive])}",
        description: "",
        job: "signal adapter",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        conversation_enabled: false,
        active: true,
        advanced_options: %{}
      })

    configured_agent
  end

  defp endpoint_attrs_fixture do
    {:ok, endpoint} =
      MCP.create_mcp_endpoint(%{
        name: "Signal Adapter Endpoint #{System.unique_integer([:positive])}",
        type: "local",
        status: "enabled",
        timeout_ms: 5000,
        command: "echo",
        args: ["ok"],
        environments: %{},
        secret_environments: %{}
      })

    {:ok, runtime_endpoint_id} = Runtime.runtime_endpoint_id(endpoint.id)
    {:ok, endpoint_attrs} = Runtime.build_endpoint_attrs(runtime_endpoint_id, endpoint)
    {runtime_endpoint_id, endpoint_attrs}
  end

  test "register/sync/unsync/refresh/unregister succeed against running server" do
    %ConfiguredAgent{} = configured_agent = configured_agent_fixture()
    assert {:ok, server_ref} = ServerManager.ensure_server(configured_agent)

    {runtime_endpoint_id, endpoint_attrs} = endpoint_attrs_fixture()

    assert :ok = SignalAdapter.register_endpoint(server_ref, endpoint_attrs)

    assert {:ok, sync_result} =
             SignalAdapter.sync_tools(server_ref, runtime_endpoint_id,
               timeout: 5_000,
               mcp_tool_prefix: "",
               mcp_tool_replace_existing: true
             )

    assert is_map(sync_result)
    assert sync_result.endpoint_id == runtime_endpoint_id

    assert {:ok, unsync_result} = SignalAdapter.unsync_tools(server_ref, runtime_endpoint_id)
    assert is_map(unsync_result)
    assert unsync_result.endpoint_id == runtime_endpoint_id

    assert :ok = SignalAdapter.refresh_endpoint(server_ref, runtime_endpoint_id)
    assert :ok = SignalAdapter.unregister_endpoint(server_ref, runtime_endpoint_id)
  end

  test "operations return errors when target server is not available" do
    dead_ref =
      {:via, Registry,
       {Jido.registry_name(Zaq.Agent.Jido), "missing_#{System.unique_integer([:positive])}"}}

    runtime_endpoint_id = :nonexistent_endpoint

    assert {:error, _reason} =
             SignalAdapter.sync_tools(dead_ref, runtime_endpoint_id, timeout: 20)

    assert {:error, _reason} =
             SignalAdapter.unsync_tools(dead_ref, runtime_endpoint_id, timeout: 20)

    assert {:error, _reason} =
             SignalAdapter.register_endpoint(dead_ref, %{endpoint_id: runtime_endpoint_id},
               timeout: 20
             )

    assert {:error, _reason} =
             SignalAdapter.refresh_endpoint(dead_ref, runtime_endpoint_id, timeout: 20)

    assert {:error, _reason} =
             SignalAdapter.unregister_endpoint(dead_ref, runtime_endpoint_id, timeout: 20)
  end
end
