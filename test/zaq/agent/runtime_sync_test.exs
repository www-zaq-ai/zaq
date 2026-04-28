defmodule Zaq.Agent.RuntimeSyncTest do
  use ExUnit.Case, async: true

  alias Zaq.Agent.ConfiguredAgent
  alias Zaq.Agent.MCP.Endpoint
  alias Zaq.Agent.RuntimeSync

  defmodule StubMCP do
    def get_mcp_endpoint(id) when is_integer(id) do
      %Endpoint{
        id: id,
        type: "local",
        status: "enabled",
        command: "echo",
        args: ["ok"],
        environments: %{},
        secret_environments: %{},
        timeout_ms: 5000
      }
    end

    def get_mcp_endpoint!(id), do: get_mcp_endpoint(id)

    def delete_mcp_endpoint(%Endpoint{} = endpoint) do
      send(self(), {:delete_mcp_endpoint_called, endpoint.id})
      {:ok, endpoint}
    end
  end

  defmodule StubSignalAdapter do
    def register_endpoint(_server_ref, _endpoint_attrs, _opts), do: :ok

    def sync_tools(_server_ref, _runtime_endpoint_id, opts) do
      result = Keyword.get(opts, :stub_sync_result)

      if result,
        do: result,
        else:
          {:ok,
           %{discovered_count: 0, registered_count: 0, failed_count: 0, failed: [], warnings: []}}
    end

    def unsync_tools(_server_ref, _runtime_endpoint_id, _opts) do
      {:ok, %{removed_count: 0, failed_count: 0, removed_tools: [], failed: []}}
    end

    def unregister_endpoint(_server_ref, runtime_endpoint_id, _opts) do
      send(self(), {:unregister_endpoint_called, runtime_endpoint_id})
      :ok
    end
  end

  defmodule StubServerManager do
    def sync_runtime(%ConfiguredAgent{id: id}) do
      {:ok, %{server_ref: {:server, id}, runtime: %{mcp: %{results: []}}}}
    end
  end

  defmodule StubAgentModule do
    def list_agents_with_mcp_endpoint(_endpoint_id) do
      [%ConfiguredAgent{id: 77, active: true}]
    end
  end

  defmodule RuntimeCustomTool do
    use Jido.Action,
      name: "runtime_custom_tool",
      description: "Custom runtime tool",
      schema: Zoi.object(%{})

    @impl true
    def run(_params, _context), do: {:ok, %{ok: true}}
  end

  test "sync_agent_configured_tools registers missing configured tools" do
    agent = %ConfiguredAgent{enabled_tool_keys: ["files.read_file"], enabled_mcp_endpoint_ids: []}

    list_tools_fn = fn :server_ref -> {:ok, []} end

    register_tool_fn = fn :server_ref, module ->
      send(self(), {:register_tool_called, module})
      {:ok, :agent}
    end

    unregister_tool_fn = fn :server_ref, name ->
      send(self(), {:unregister_tool_called, name})
      {:ok, :agent}
    end

    assert {:ok, result} =
             RuntimeSync.sync_agent_configured_tools(agent, :server_ref,
               list_tools_fn: list_tools_fn,
               register_tool_fn: register_tool_fn,
               unregister_tool_fn: unregister_tool_fn
             )

    assert "read_file" in result.added_tools
    assert result.removed_tools == []
    assert_receive {:register_tool_called, Jido.Tools.Files.ReadFile}
    refute_receive {:unregister_tool_called, _}
  end

  test "sync_agent_configured_tools removes stale managed tools and keeps non-managed tools" do
    agent = %ConfiguredAgent{enabled_tool_keys: [], enabled_mcp_endpoint_ids: []}

    list_tools_fn = fn :server_ref -> {:ok, [Jido.Tools.Files.ReadFile, RuntimeCustomTool]} end

    register_tool_fn = fn :server_ref, module ->
      send(self(), {:register_tool_called, module})
      {:ok, :agent}
    end

    unregister_tool_fn = fn :server_ref, name ->
      send(self(), {:unregister_tool_called, name})
      {:ok, :agent}
    end

    assert {:ok, result} =
             RuntimeSync.sync_agent_configured_tools(agent, :server_ref,
               list_tools_fn: list_tools_fn,
               register_tool_fn: register_tool_fn,
               unregister_tool_fn: unregister_tool_fn
             )

    assert result.added_tools == []
    assert "read_file" in result.removed_tools
    assert_receive {:unregister_tool_called, "read_file"}
    refute_receive {:unregister_tool_called, "runtime_custom_tool"}
    refute_receive {:register_tool_called, _}
  end

  test "sync_agent_configured_tools returns error for unknown configured tool keys" do
    agent = %ConfiguredAgent{enabled_tool_keys: ["files.missing"], enabled_mcp_endpoint_ids: []}

    assert {:error, {:unknown_tools, ["files.missing"]}} =
             RuntimeSync.sync_agent_configured_tools(agent, :server_ref)
  end

  test "sync_agent_mcp_assignments returns warning when endpoint exposes zero tools" do
    agent = %ConfiguredAgent{id: 7, enabled_tool_keys: [], enabled_mcp_endpoint_ids: [1]}

    assert {:ok, result} =
             RuntimeSync.sync_agent_mcp_assignments(agent, :server_ref,
               mcp_module: StubMCP,
               endpoint_count_fn: fn -> 0 end,
               signal_adapter_module: StubSignalAdapter,
               stub_sync_result:
                 {:ok,
                  %{
                    discovered_count: 0,
                    registered_count: 0,
                    failed_count: 0,
                    failed: [],
                    warnings: []
                  }}
             )

    assert result.synced_endpoint_ids == [1]
    assert [%{status: :warning, reason: :no_tools_discovered}] = result.warnings
  end

  test "sync_agent_mcp_assignments errors when tools are discovered but none register" do
    agent = %ConfiguredAgent{id: 8, enabled_tool_keys: [], enabled_mcp_endpoint_ids: [1]}

    assert {:error, {:mcp_sync_failed, details}} =
             RuntimeSync.sync_agent_mcp_assignments(agent, :server_ref,
               mcp_module: StubMCP,
               endpoint_count_fn: fn -> 0 end,
               signal_adapter_module: StubSignalAdapter,
               stub_sync_result:
                 {:ok,
                  %{
                    discovered_count: 3,
                    registered_count: 0,
                    failed_count: 3,
                    failed: ["a"],
                    warnings: []
                  }}
             )

    assert details.endpoint_id == 1

    assert match?(
             {:mcp_tools_not_registered, %{endpoint_id: 1, discovered_count: 3, result: _}},
             details.reason
           )
  end

  test "mcp_endpoint_updated deletes endpoint and unsyncs impacted active agents" do
    assert {:ok, %{endpoint: endpoint, runtime: runtime}} =
             RuntimeSync.mcp_endpoint_updated(%{action: :delete, id: 12},
               mcp_module: StubMCP,
               agent_module: StubAgentModule,
               server_manager_module: StubServerManager,
               signal_adapter_module: StubSignalAdapter,
               endpoint_count_fn: fn -> 0 end,
               atom_count_fn: fn -> 100 end
             )

    assert endpoint.id == 12
    assert runtime.endpoint_id == 12
    assert runtime.endpoint_status == "disabled"
    assert runtime.impacted_agent_ids == [77]
    assert_received {:delete_mcp_endpoint_called, 12}
  end
end
