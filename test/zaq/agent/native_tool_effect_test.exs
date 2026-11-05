defmodule Zaq.Agent.RequestEffectCharacterizationTest do
  use Zaq.DataCase, async: false

  alias Zaq.Agent.{Factory, ServerManager}
  alias Zaq.TestSupport.{IntegrationAgent, RequestEffectProbe, ToolCallingLLMStub}

  test "native request identity reaches validated tools and effects reach the owning Jido state" do
    routes = [
      %{
        match: fn _ -> true end,
        tool: "request_effect_probe",
        arguments: fn _ -> %{value: "accepted"} end
      }
    ]

    {child, endpoint} = ToolCallingLLMStub.server(routes, final_response: "Done.")
    start_supervised!(child)
    scope = "effect-#{Ecto.UUID.generate()}"
    configured = IntegrationAgent.create!(endpoint, scope, "Use the probe.", [])

    {:ok, server} =
      ServerManager.ensure_server(configured, "#{configured.name}:#{scope}", nil,
        actor: %{kind: :system, subject: "effect-test"}
      )

    assert {:ok, _} = Jido.AI.register_tool(server, RequestEffectProbe)

    assert {:ok, %{request: request, events: events}} =
             Factory.ask_with_config(server, "Probe", configured,
               tool_context: %{test_pid: self()}
             )

    observed = Enum.to_list(events)
    assert_receive {:request_effect_context, context}, 5_000
    assert context.request_id == request.id
    assert context.run_id == request.id
    assert context.agent_module == Factory
    assert is_map(context.state)
    assert is_binary(context.execution_root)

    assert {:ok, status} = Jido.AgentServer.status(server)
    assert status.raw_state.request_effect_probe == "accepted"

    completed = Enum.find(observed, &(&1.kind == :tool_completed))
    assert {:ok, _, [%Jido.Agent.StateOp.SetPath{}]} = completed.data.result
    assert List.last(observed).kind == :request_completed
    refute_received {:llm_stub_error, _}
  end
end
