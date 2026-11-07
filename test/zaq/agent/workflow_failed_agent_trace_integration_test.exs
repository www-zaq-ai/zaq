defmodule Zaq.Agent.WorkflowFailedAgentTraceIntegrationTest do
  use Zaq.DataCase, async: false

  alias Zaq.Agent.ServerManager
  alias Zaq.Agent.Tools.Workflow.RunAgent
  alias Zaq.Contracts.ToolStep
  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.Step.Run, as: StepRun
  alias Zaq.Engine.Workflows.StepRunner
  alias Zaq.TestSupport.{IntegrationAgent, MultiAgentOpenAIStub, NestedActionProbe, OpenAIStub}
  alias ZaqWeb.Live.BO.AI.WorkflowResultHelpers

  for {outcome, observed_tools?} <- [{:failed, true}, {:completed, true}, {:failed, false}] do
    test "#{outcome} native agent step preserves diagnostics with observed tools=#{observed_tools?}" do
      assert_observed_workflow_trace(unquote(outcome), unquote(observed_tools?))
    end
  end

  defp assert_observed_workflow_trace(outcome, observed_tools?) do
    owner = self()
    set_mox_global()
    stub(Zaq.NodeRouterMock, :find_node, fn _ -> node() end)
    stub(Zaq.NodeRouterMock, :dispatch, fn event -> event end)

    {child, endpoint} =
      OpenAIStub.server(
        fn _conn, raw_body ->
          request = MultiAgentOpenAIStub.decode_request!(raw_body)

          if observed_tools? and MultiAgentOpenAIStub.tool_results(request) == [] do
            {200,
             MultiAgentOpenAIStub.tool_call_sse("nested_action_probe", %{depth: 2},
               call_id: "opaque.failed.workflow.root"
             )}
          else
            send(owner, :provider_terminal_response_observed)

            provider_reply(outcome)
          end
        end,
        owner
      )

    start_supervised!(child)

    {:ok, workflow} =
      Workflows.create_workflow(%{
        name: "Native failure evidence",
        steps: %{"nodes" => [], "edges" => []}
      })

    actor = %{kind: :system, subject: "failed-workflow-trace-integration"}

    {:ok, run} =
      Workflows.create_run(workflow, %{
        "request" => nil,
        "actor" => actor,
        "assigns" => %{}
      })

    scope = "workflow:run:#{run.id}:step:0"
    configured = IntegrationAgent.create!(endpoint, scope, "Use the nested probe.", [])

    assert {:ok, server} =
             ServerManager.ensure_server(configured, "#{configured.name}:#{scope}", nil,
               actor: actor
             )

    assert {:ok, _} = Jido.AI.register_tool(server, NestedActionProbe)

    result =
      StepRunner.run(
        %{
          wrapped_module: RunAgent,
          run_id: run.id,
          step_name: "configured_agent",
          step_index: 0,
          agent_id: configured.id,
          input: "Use the nested probe then report"
        },
        %{}
      )

    assert_received :provider_terminal_response_observed
    [step] = Workflows.list_step_runs(run.id)
    persisted = Repo.get!(StepRun, step.id)
    assert persisted.status == Atom.to_string(outcome)

    case outcome do
      :failed ->
        assert {:error, _} = result
        assert persisted.errors["reason"] == "agent_failed::provider_rate_limited"
        refute Map.has_key?(persisted.results, "output")
        refute Map.has_key?(persisted.results, "__cascade__")

      :completed ->
        assert {:ok, _} = result
        assert persisted.results["output"] == "Nested workflow completed"
    end

    trace = persisted.results["trace"]
    assert is_list(trace)

    children = Enum.filter(trace, &(&1["origin"] == "zaq_action"))

    if observed_tools? do
      assert persisted.results["measurements"]["tool_call_count"] == 1

      assert [%{"id" => "opaque.failed.workflow.root", "state" => "succeeded"}] =
               ToolStep.project(trace)

      assert length(children) == 2
      assert Enum.map(children, &length(&1["invocation_path"])) == [2, 3]
      assert Enum.all?(children, &(&1["outcome"] == "succeeded"))
      assert Enum.all?(children, &(hd(&1["invocation_path"]) == "opaque.failed.workflow.root"))
    else
      assert children == []
      assert ToolStep.project(trace) == []
    end

    assert WorkflowResultHelpers.agent_trace_info(persisted.results).traces == trace
    assert persisted.trace_events == []
    refute_received {:llm_stub_error, _}
  end

  defp provider_reply(:failed) do
    {429,
     Jason.encode!(%{error: %{type: "rate_limit_error", message: "Fixture provider rate limit"}})}
  end

  defp provider_reply(:completed),
    do: {200, MultiAgentOpenAIStub.text_sse("Nested workflow completed", "gpt-4.1-mini")}
end
