defmodule Zaq.Engine.Workflows.RunAgentFailureTraceTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties

  import ExUnit.CaptureLog

  alias Jido.Action.Error.ExecutionFailureError
  alias Zaq.Agent.Tools.ActionContract
  alias Zaq.Agent.Tools.Error, as: ToolError
  alias Zaq.Agent.Tools.Workflow.RunAgent
  alias Zaq.Engine.Messages.Outgoing
  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.Step.Run, as: StepRun
  alias Zaq.Engine.Workflows.StepRunner

  defmodule FailedAgentRouter do
    def dispatch(event) do
      %{
        event
        | response: %Outgoing{
            body: "The selected agent could not finish.",
            channel_id: event.request.channel_id,
            provider: nil,
            metadata: %{
              error: true,
              reason: "llm_timeout",
              model: "fixture-model",
              agent: %{id: 42, name: "Configured workflow agent"},
              measurements: %{"tool_call_count" => 1},
              trace: [
                %{
                  "id" => "opaque.native.root",
                  "type" => "tool_call",
                  "tool_name" => "web_browsing",
                  "outcome" => "succeeded",
                  "status" => "completed"
                }
              ]
            }
          }
      }
    end
  end

  defmodule ConfiguredAgentStep do
    def run(params, context) do
      RunAgent.run(params, Map.put(context, :node_router, FailedAgentRouter))
    end
  end

  defmodule DiagnosticFailureStep do
    def run(%{failure: failure}, _context), do: {:error, failure}
  end

  setup do
    stub(Zaq.NodeRouterMock, :dispatch, fn event -> event end)
    :ok
  end

  test "a failed configured agent step persists observed diagnostics without succeeding" do
    run = create_run()

    params = %{
      wrapped_module: ConfiguredAgentStep,
      run_id: run.id,
      step_name: "configured_agent",
      step_index: 0,
      agent_id: 42,
      input: "Browse and report"
    }

    assert {:error, _} = StepRunner.run(params, %{})
    [step] = Workflows.list_step_runs(run.id)
    assert step.status == "failed"
    assert step.errors["reason"] == "agent_failed:llm_timeout"

    persisted = Repo.get!(StepRun, step.id)
    assert persisted.results["model"] == "fixture-model"
    assert persisted.results["agent"]["id"] == 42
    assert persisted.results["measurements"]["tool_call_count"] == 1

    assert [%{"id" => "opaque.native.root", "outcome" => "succeeded"}] =
             persisted.results["trace"]

    refute Map.has_key?(persisted.results, "__cascade__")
    assert [%{"event" => "step_failed"}] = persisted.logs
    assert persisted.trace_events == []
  end

  test "real Jido execution preserves diagnostic failures without exposing them as tool text" do
    assert {:error, %ExecutionFailureError{} = error} =
             ActionContract.execute(
               RunAgent,
               %{agent_id: 42, input: "Browse and report"},
               %{node_router: FailedAgentRouter}
             )

    assert error.message == "agent_failed:llm_timeout"
    assert [%{"id" => "opaque.native.root"}] = error.details.workflow_results.trace
    assert ToolError.format(error) == "agent_failed:llm_timeout"
  end

  property "failure diagnostics remain opaque and never enter cascade or failure logs" do
    check all(value <- string(:alphanumeric, min_length: 1, max_length: 30)) do
      run = create_run()
      diagnostic = %{"private_diagnostic" => "PRIVATE_DIAGNOSTIC_#{value}"}

      failure =
        ExecutionFailureError.exception(
          message: "action_failed",
          details: %{workflow_results: diagnostic}
        )

      log =
        capture_log(fn ->
          assert {:error, ^failure} =
                   StepRunner.run(
                     %{
                       wrapped_module: DiagnosticFailureStep,
                       run_id: run.id,
                       step_name: "diagnostic_failure",
                       step_index: 0,
                       failure: failure
                     },
                     %{}
                   )
        end)

      [step] = Workflows.list_step_runs(run.id)
      assert step.status == "failed"
      assert step.results == diagnostic
      assert step.errors == %{"reason" => "action_failed"}
      refute Map.has_key?(step.results, "__cascade__")
      refute log =~ "PRIVATE_DIAGNOSTIC_"
      refute Jason.encode!(step.logs) =~ "PRIVATE_DIAGNOSTIC_"
    end
  end

  test "isolated map failure retains diagnostics without passing partial output downstream" do
    run = create_run()

    failure =
      ExecutionFailureError.exception(
        message: "action_failed",
        details: %{workflow_results: %{"observed" => 42}}
      )

    assert {:ok, %{"__map_error__" => true, "__map_index__" => 0} = result} =
             StepRunner.run(
               %{
                 wrapped_module: DiagnosticFailureStep,
                 run_id: run.id,
                 step_name: "diagnostic_failure",
                 step_index: 0,
                 failure: failure,
                 __map_index__: 0,
                 __map_strategy__: :skip_and_continue
               },
               %{}
             )

    refute Map.has_key?(result, "observed")
    [step] = Workflows.list_step_runs(run.id)
    assert step.status == "failed_fatal"
    assert step.results == %{"observed" => 42}
  end

  defp create_run do
    {:ok, workflow} =
      Workflows.create_workflow(%{
        name: "Failed agent diagnostics",
        steps: %{"nodes" => [], "edges" => []}
      })

    {:ok, run} = Workflows.create_run(workflow, %{"request" => nil, "assigns" => %{}})
    run
  end
end
