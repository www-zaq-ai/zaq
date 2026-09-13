defmodule Zaq.Agent.FactoryToolTimeoutIntegrationTest do
  use Zaq.DataCase, async: false

  alias Zaq.Agent.{Factory, ServerManager}
  alias Zaq.Agent.Tools.Web.Browsing
  alias Zaq.TestSupport.{BudgetProbeTool, IntegrationAgent, ToolCallingLLMStub}

  test "real tool continuation uses live budgets after hot tool reconfiguration" do
    routes = [
      %{match: fn _ -> true end, tool: "budget_probe", arguments: fn _ -> %{value: "done"} end}
    ]

    {child, endpoint} =
      ToolCallingLLMStub.server(routes, max_interactions: 3, final_response: "Probe completed.")

    start_supervised!(child)
    scope = "budget-#{Ecto.UUID.generate()}"
    configured = IntegrationAgent.create!(endpoint, scope, "Use the probe tool.", [])
    {:ok, server} = ServerManager.ensure_server(configured, "#{configured.name}:#{scope}")
    assert {:ok, _} = Jido.AI.register_tool(server, BudgetProbeTool)

    browser_budget = max(Browsing.tool_timeout_ms(), BudgetProbeTool.tool_timeout_ms())

    for {keys, expected_budget} <- [
          {[], 45_000},
          {["web.browsing"], browser_budget},
          {[], 45_000}
        ] do
      updated = %{configured | enabled_tool_keys: keys}
      assert {:ok, _} = ServerManager.sync_runtime(updated)

      assert {:ok, request} =
               Factory.ask_with_config(server, "Run the probe", updated,
                 tool_context: %{test_pid: self()},
                 timeout: 10_000
               )

      assert_receive {:budget_probe_started, tool_pid, "done"}, 5_000
      assert {:ok, status} = Jido.AgentServer.status(server)
      assert status.raw_state.__strategy__.config.tool_timeout_ms == expected_budget
      send(tool_pid, :release)
      assert {:ok, "Probe completed."} = Factory.await(request, timeout: 10_000)

      assert_received {:llm_tool_result, "budget_probe",
                       %{"ok" => true, "result" => %{"value" => "done"}}}

      assert {:ok, %{status: :completed}} =
               Jido.AgentServer.await_completion(server,
                 status_path: [:__strategy__, :status],
                 timeout: 5_000
               )
    end

    refute_received {:llm_stub_error, _}
  end
end
