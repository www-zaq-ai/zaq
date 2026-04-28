defmodule Zaq.Agent.RuntimeSyncTest do
  use Zaq.DataCase, async: false

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

  defmodule StubAgentLifecycleModule do
    def create_agent(attrs), do: {:ok, struct(ConfiguredAgent, Map.merge(%{id: 501}, attrs))}

    def get_agent!(id), do: %ConfiguredAgent{id: id, active: true, enabled_mcp_endpoint_ids: []}

    def update_agent(existing, attrs), do: {:ok, struct(existing, attrs)}

    def delete_agent(%ConfiguredAgent{} = agent), do: {:ok, agent}

    def list_agents_with_mcp_endpoint(_endpoint_id), do: []
  end

  defmodule StubAgentNoRuntimeChangeModule do
    def create_agent(attrs), do: {:ok, struct(ConfiguredAgent, Map.merge(%{id: 601}, attrs))}

    def get_agent!(id) do
      %ConfiguredAgent{
        id: id,
        model: "gpt-4.1-mini",
        credential_id: 1,
        enabled_tool_keys: ["files.read_file"],
        enabled_mcp_endpoint_ids: [1],
        advanced_options: %{"temperature" => 0.1},
        active: true,
        job: "job",
        strategy: "react"
      }
    end

    def update_agent(existing, attrs), do: {:ok, struct(existing, attrs)}
    def delete_agent(agent), do: {:ok, agent}
    def list_agents_with_mcp_endpoint(_endpoint_id), do: []
  end

  defmodule StubServerManagerForPatch do
    def sync_runtime(_agent) do
      {:ok,
       %{
         server_ref: :server_ref,
         runtime: %{tools: %{added_tools: []}, mcp: %{results: [], warnings: []}}
       }}
    end

    def stop_server(id) do
      send(self(), {:stop_server_called, id})
      :ok
    end
  end

  defmodule StubServerManagerError do
    def sync_runtime(_agent), do: {:error, :sync_runtime_failed}
    def stop_server(_id), do: :ok
  end

  defmodule StubSignalAdapterUnsyncError do
    def register_endpoint(_server_ref, _endpoint_attrs, _opts), do: :ok

    def sync_tools(_server_ref, _runtime_endpoint_id, _opts),
      do: {:ok, %{discovered_count: 1, registered_count: 1, failed_count: 0}}

    def unsync_tools(_server_ref, _runtime_endpoint_id, _opts), do: {:error, :unsync_failed}
    def unregister_endpoint(_server_ref, _runtime_endpoint_id, _opts), do: :ok
  end

  defmodule StubSignalAdapterUnsyncStatusError do
    def register_endpoint(_server_ref, _endpoint_attrs, _opts), do: :ok

    def sync_tools(_server_ref, _runtime_endpoint_id, _opts),
      do: {:ok, %{discovered_count: 1, registered_count: 1, failed_count: 0}}

    def unsync_tools(_server_ref, _runtime_endpoint_id, _opts), do: {:ok, %{status: :error}}
    def unregister_endpoint(_server_ref, _runtime_endpoint_id, _opts), do: :ok
  end

  defmodule StubSignalAdapterUnsyncInvalid do
    def register_endpoint(_server_ref, _endpoint_attrs, _opts), do: :ok

    def sync_tools(_server_ref, _runtime_endpoint_id, _opts),
      do: {:ok, %{discovered_count: 1, registered_count: 1, failed_count: 0}}

    def unsync_tools(_server_ref, _runtime_endpoint_id, _opts), do: {:ok, :invalid_payload}
    def unregister_endpoint(_server_ref, _runtime_endpoint_id, _opts), do: :ok
  end

  defmodule StubAgentLifecycleErrorModule do
    def create_agent(_attrs), do: {:error, :create_failed}
    def get_agent!(id), do: %ConfiguredAgent{id: id, active: true, enabled_mcp_endpoint_ids: []}
    def update_agent(_existing, _attrs), do: {:error, :update_failed}
    def delete_agent(_agent), do: {:error, :delete_failed}
    def list_agents_with_mcp_endpoint(_endpoint_id), do: []
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

  test "sync_agent_runtime returns tools and mcp payloads" do
    agent = %ConfiguredAgent{id: 15, enabled_tool_keys: [], enabled_mcp_endpoint_ids: []}

    assert {:ok, %{tools: tools, mcp: mcp}} =
             RuntimeSync.sync_agent_runtime(agent, :server_ref,
               list_tools_fn: fn _ -> {:ok, []} end
             )

    assert is_map(tools)
    assert is_map(mcp)
  end

  test "sync_agent_runtime returns error when list_tools returns invalid payload" do
    agent = %ConfiguredAgent{id: 16, enabled_tool_keys: [], enabled_mcp_endpoint_ids: []}

    assert {:error, {:invalid_list_tools_response, :bad}} =
             RuntimeSync.sync_agent_runtime(agent, :server_ref, list_tools_fn: fn _ -> :bad end)
  end

  test "sync_agent_mcp_assignments skips missing and disabled endpoints" do
    defmodule SkipMCP do
      alias Zaq.Agent.MCP.Endpoint

      def get_mcp_endpoint(1), do: nil
      def get_mcp_endpoint(2), do: %Endpoint{id: 2, status: "disabled", type: "local"}
    end

    agent = %ConfiguredAgent{id: 17, enabled_tool_keys: [], enabled_mcp_endpoint_ids: [1, 2]}

    assert {:ok, result} =
             RuntimeSync.sync_agent_mcp_assignments(agent, :server_ref,
               mcp_module: SkipMCP,
               signal_adapter_module: StubSignalAdapter
             )

    assert result.synced_endpoint_ids == []
    assert result.skipped_endpoint_ids == [1, 2]
  end

  test "sync_agent_mcp_assignments supports aggregated metrics from nested results" do
    defmodule MCPForNestedMetrics do
      alias Zaq.Agent.MCP.Endpoint

      def get_mcp_endpoint(1),
        do: %Endpoint{
          id: 1,
          type: "local",
          status: "enabled",
          command: "echo",
          args: ["ok"],
          environments: %{},
          secret_environments: %{},
          timeout_ms: 5000
        }
    end

    defmodule SignalAdapterNestedMetrics do
      def register_endpoint(_server_ref, _endpoint_attrs, _opts), do: :ok

      def sync_tools(_server_ref, _runtime_endpoint_id, _opts) do
        {:ok,
         %{
           results: [
             %{status: :ok, result: %{discovered_count: 1, registered_count: 1, failed_count: 0}},
             %{status: :ok, result: %{discovered_count: 2, registered_count: 1, failed_count: 1}}
           ]
         }}
      end

      def unsync_tools(_server_ref, _runtime_endpoint_id, _opts), do: {:ok, %{removed_count: 0}}
      def unregister_endpoint(_server_ref, _runtime_endpoint_id, _opts), do: :ok
    end

    agent = %ConfiguredAgent{id: 20, enabled_tool_keys: [], enabled_mcp_endpoint_ids: [1]}

    assert {:ok, result} =
             RuntimeSync.sync_agent_mcp_assignments(agent, :server_ref,
               mcp_module: MCPForNestedMetrics,
               signal_adapter_module: SignalAdapterNestedMetrics
             )

    assert [%{status: :warning, reason: :partial_tool_sync}] = result.warnings
  end

  test "sync_agent_mcp_assignments errors for invalid nested result entry" do
    defmodule MCPForInvalidNested do
      alias Zaq.Agent.MCP.Endpoint

      def get_mcp_endpoint(1),
        do: %Endpoint{
          id: 1,
          type: "local",
          status: "enabled",
          command: "echo",
          args: ["ok"],
          environments: %{},
          secret_environments: %{},
          timeout_ms: 5000
        }
    end

    defmodule SignalAdapterInvalidNested do
      def register_endpoint(_server_ref, _endpoint_attrs, _opts), do: :ok
      def unsync_tools(_server_ref, _runtime_endpoint_id, _opts), do: {:ok, %{removed_count: 0}}
      def unregister_endpoint(_server_ref, _runtime_endpoint_id, _opts), do: :ok

      def sync_tools(_server_ref, _runtime_endpoint_id, _opts) do
        {:ok, %{results: [%{status: :error, reason: :tool_failure}]}}
      end
    end

    agent = %ConfiguredAgent{id: 21, enabled_tool_keys: [], enabled_mcp_endpoint_ids: [1]}

    assert {:error, {:mcp_sync_failed, details}} =
             RuntimeSync.sync_agent_mcp_assignments(agent, :server_ref,
               mcp_module: MCPForInvalidNested,
               signal_adapter_module: SignalAdapterInvalidNested
             )

    assert details.endpoint_id == 1
    assert match?({:mcp_sync_failed, _}, details.reason)
  end

  test "sync_agent_mcp_assignments errors for invalid sync payload type" do
    defmodule MCPForInvalidSyncPayload do
      alias Zaq.Agent.MCP.Endpoint

      def get_mcp_endpoint(1),
        do: %Endpoint{
          id: 1,
          type: "local",
          status: "enabled",
          command: "echo",
          args: ["ok"],
          environments: %{},
          secret_environments: %{},
          timeout_ms: 5000
        }
    end

    defmodule SignalAdapterInvalidSyncPayload do
      def register_endpoint(_server_ref, _endpoint_attrs, _opts), do: :ok
      def unsync_tools(_server_ref, _runtime_endpoint_id, _opts), do: {:ok, %{removed_count: 0}}
      def unregister_endpoint(_server_ref, _runtime_endpoint_id, _opts), do: :ok
      def sync_tools(_server_ref, _runtime_endpoint_id, _opts), do: {:ok, :not_a_map}
    end

    agent = %ConfiguredAgent{id: 22, enabled_tool_keys: [], enabled_mcp_endpoint_ids: [1]}

    assert {:error, {:mcp_sync_failed, details}} =
             RuntimeSync.sync_agent_mcp_assignments(agent, :server_ref,
               mcp_module: MCPForInvalidSyncPayload,
               signal_adapter_module: SignalAdapterInvalidSyncPayload
             )

    assert details.endpoint_id == 1
    assert match?({:invalid_mcp_sync_result, _}, details.reason)
  end

  test "sync_agent_mcp_assignments handles direct signal adapter error" do
    defmodule MCPForDirectSyncError do
      alias Zaq.Agent.MCP.Endpoint

      def get_mcp_endpoint(1),
        do: %Endpoint{
          id: 1,
          type: "local",
          status: "enabled",
          command: "echo",
          args: ["ok"],
          environments: %{},
          secret_environments: %{},
          timeout_ms: 5000
        }
    end

    defmodule SignalAdapterDirectSyncError do
      def register_endpoint(_server_ref, _endpoint_attrs, _opts), do: :ok
      def unsync_tools(_server_ref, _runtime_endpoint_id, _opts), do: {:ok, %{removed_count: 0}}
      def unregister_endpoint(_server_ref, _runtime_endpoint_id, _opts), do: :ok
      def sync_tools(_server_ref, _runtime_endpoint_id, _opts), do: {:error, :transport_down}
    end

    agent = %ConfiguredAgent{id: 23, enabled_tool_keys: [], enabled_mcp_endpoint_ids: [1]}

    assert {:error, {:mcp_sync_failed, details}} =
             RuntimeSync.sync_agent_mcp_assignments(agent, :server_ref,
               mcp_module: MCPForDirectSyncError,
               signal_adapter_module: SignalAdapterDirectSyncError
             )

    assert details.endpoint_id == 1
    assert details.reason == :transport_down
  end

  test "configured_agent lifecycle delegates and propagates failures" do
    assert {:ok, %{agent: %ConfiguredAgent{id: 501}}} =
             RuntimeSync.configured_agent_created(%{name: "A"},
               agent_module: StubAgentLifecycleModule,
               server_manager_module: StubServerManager
             )

    assert {:error, :create_failed} =
             RuntimeSync.configured_agent_created(%{name: "A"},
               agent_module: StubAgentLifecycleErrorModule
             )

    assert {:error, :update_failed} =
             RuntimeSync.configured_agent_updated(9, %{name: "B"},
               agent_module: StubAgentLifecycleErrorModule
             )

    assert {:error, :delete_failed} =
             RuntimeSync.configured_agent_deleted(9,
               agent_module: StubAgentLifecycleErrorModule
             )
  end

  test "mcp_endpoint_updated rejects invalid requests" do
    assert {:error, {:invalid_request, %{action: :unknown}}} =
             RuntimeSync.mcp_endpoint_updated(%{action: :unknown}, mcp_module: StubMCP)
  end

  test "mcp_endpoint_updated supports string action for enable_predefined" do
    defmodule EnableMCP do
      alias Zaq.Agent.MCP.Endpoint

      def enable_predefined("github_mcp") do
        {:ok,
         %Endpoint{id: 31, status: "enabled", type: "remote", url: "http://localhost:8123/mcp"}}
      end

      def get_mcp_endpoint(_), do: nil
    end

    assert {:ok, %{endpoint: endpoint, runtime: runtime}} =
             RuntimeSync.mcp_endpoint_updated(
               %{"action" => "enable_predefined", "predefined_id" => "github_mcp"},
               mcp_module: EnableMCP,
               agent_module: StubAgentLifecycleModule
             )

    assert endpoint.id == 31
    assert runtime.endpoint_status == "enabled"
  end

  test "configured_agent_updated returns no_runtime_change when tracked fields are unchanged" do
    assert {:ok, %{runtime: %{strategy: :no_runtime_change}}} =
             RuntimeSync.configured_agent_updated(
               77,
               %{
                 model: "gpt-4.1-mini",
                 credential_id: 1,
                 enabled_tool_keys: ["files.read_file"],
                 enabled_mcp_endpoint_ids: [1],
                 advanced_options: %{"temperature" => 0.1},
                 active: true,
                 job: "job",
                 strategy: "react"
               },
               agent_module: StubAgentNoRuntimeChangeModule,
               server_manager_module: StubServerManagerForPatch
             )
  end

  test "configured_agent_updated drains and stops when updated agent is inactive" do
    assert {:ok, %{runtime: %{strategy: :drain_and_stop}}} =
             RuntimeSync.configured_agent_updated(78, %{active: false},
               agent_module: StubAgentNoRuntimeChangeModule,
               server_manager_module: StubServerManagerForPatch
             )

    assert_received {:stop_server_called, 78}
  end

  test "configured_agent_updated returns hot_runtime_patch and unsync results" do
    assert {:ok, %{runtime: runtime}} =
             RuntimeSync.configured_agent_updated(
               79,
               %{
                 enabled_mcp_endpoint_ids: [],
                 advanced_options: %{"temperature" => 0.2}
               },
               agent_module: StubAgentNoRuntimeChangeModule,
               server_manager_module: StubServerManagerForPatch,
               signal_adapter_module: StubSignalAdapter
             )

    assert runtime.strategy == :hot_runtime_patch
    assert runtime.removed_mcp_endpoint_ids == [1]
    assert is_list(runtime.unsync_results)
  end

  test "configured_agent_updated propagates sync_runtime errors" do
    assert {:error, :sync_runtime_failed} =
             RuntimeSync.configured_agent_updated(80, %{job: "changed"},
               agent_module: StubAgentNoRuntimeChangeModule,
               server_manager_module: StubServerManagerError
             )
  end

  test "configured_agent_updated propagates unsync failures" do
    assert {:error, :unsync_failed} =
             RuntimeSync.configured_agent_updated(
               81,
               %{
                 enabled_mcp_endpoint_ids: [],
                 advanced_options: %{"temperature" => 0.2}
               },
               agent_module: StubAgentNoRuntimeChangeModule,
               server_manager_module: StubServerManagerForPatch,
               signal_adapter_module: StubSignalAdapterUnsyncError
             )
  end

  test "configured_agent_updated maps unsync status error payload to mcp_unsync_failed" do
    assert {:error, {:mcp_unsync_failed, %{endpoint_id: 1}}} =
             RuntimeSync.configured_agent_updated(
               82,
               %{
                 enabled_mcp_endpoint_ids: [],
                 advanced_options: %{"temperature" => 0.2}
               },
               agent_module: StubAgentNoRuntimeChangeModule,
               server_manager_module: StubServerManagerForPatch,
               signal_adapter_module: StubSignalAdapterUnsyncStatusError
             )
  end

  test "configured_agent_updated maps invalid unsync payload to invalid_mcp_unsync_result" do
    assert {:error, {:invalid_mcp_unsync_result, %{endpoint_id: 1}}} =
             RuntimeSync.configured_agent_updated(
               83,
               %{
                 enabled_mcp_endpoint_ids: [],
                 advanced_options: %{"temperature" => 0.2}
               },
               agent_module: StubAgentNoRuntimeChangeModule,
               server_manager_module: StubServerManagerForPatch,
               signal_adapter_module: StubSignalAdapterUnsyncInvalid
             )
  end

  test "configured_agent_deleted returns drain_and_stop strategy on success" do
    assert {:ok, %{agent: %ConfiguredAgent{id: 99}, runtime: %{strategy: :drain_and_stop}}} =
             RuntimeSync.configured_agent_deleted(99,
               agent_module: StubAgentLifecycleModule
             )
  end

  test "sync_agent_configured_tools propagates list_tools error" do
    agent = %ConfiguredAgent{id: 18, enabled_tool_keys: [], enabled_mcp_endpoint_ids: []}

    assert {:error, :list_failed} =
             RuntimeSync.sync_agent_configured_tools(agent, :server_ref,
               list_tools_fn: fn _ -> {:error, :list_failed} end
             )
  end
end
