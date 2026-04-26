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

    mcp_sync_fn = fn _endpoint_id, _agent_server, _options ->
      %{
        status: :ok,
        operation: :sync,
        endpoint_id: :mcp_1,
        attempted: 1,
        succeeded: 1,
        failed: 0,
        results: [
          %{
            status: :ok,
            result: %{
              discovered_count: 0,
              registered_count: 0,
              failed_count: 0,
              failed: [],
              warnings: %{}
            }
          }
        ]
      }
    end

    assert {:ok, result} =
             RuntimeSync.sync_agent_mcp_assignments(agent, :server_ref,
               mcp_module: StubMCP,
               endpoint_count_fn: fn -> 0 end,
                register_fn: fn _endpoint -> :ok end,
                refresh_fn: fn _endpoint_id -> :ok end,
                mcp_sync_fn: mcp_sync_fn
              )

    assert result.synced_endpoint_ids == [1]
    assert [%{status: :warning, reason: :no_tools_discovered}] = result.warnings
  end

  test "sync_agent_mcp_assignments errors when tools are discovered but none register" do
    agent = %ConfiguredAgent{id: 8, enabled_tool_keys: [], enabled_mcp_endpoint_ids: [1]}

    mcp_sync_fn = fn _endpoint_id, _agent_server, _options ->
      %{
        status: :ok,
        operation: :sync,
        endpoint_id: :mcp_1,
        attempted: 1,
        succeeded: 1,
        failed: 0,
        results: [
          %{
            status: :ok,
            result: %{
              discovered_count: 3,
              registered_count: 0,
              failed_count: 3,
              failed: ["a"],
              warnings: %{}
            }
          }
        ]
      }
    end

    assert {:error, {:mcp_sync_failed, details}} =
             RuntimeSync.sync_agent_mcp_assignments(agent, :server_ref,
               mcp_module: StubMCP,
               endpoint_count_fn: fn -> 0 end,
                register_fn: fn _endpoint -> :ok end,
                refresh_fn: fn _endpoint_id -> :ok end,
                mcp_sync_fn: mcp_sync_fn
              )

    assert details.endpoint_id == 1

    assert match?(
             {:mcp_tools_not_registered, %{endpoint_id: 1, discovered_count: 3, result: _}},
             details.reason
           )
  end
end
