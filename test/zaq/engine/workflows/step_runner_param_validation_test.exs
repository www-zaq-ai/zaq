defmodule Zaq.Engine.Workflows.StepRunnerParamValidationTest do
  @moduledoc """
  The `param_validation: :warn` escape hatch.

  Run-time schema enforcement is new for every action — `StepRunner` calls `mod.run/2`
  directly and never went through `Jido.Exec` — so a fleet whose stored workflows have
  not been swept can downgrade a refusal to a log for one release.

  `async: false`: the mode is application env, which is global.
  """
  use Zaq.DataCase, async: false

  import ExUnit.CaptureLog

  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.StepRunner
  alias Zaq.Engine.Workflows.Test.TypedParamAction

  setup do
    stub(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{} = event -> event end)

    previous = Application.get_env(:zaq, Zaq.Engine.Workflows, [])

    Application.put_env(
      :zaq,
      Zaq.Engine.Workflows,
      Keyword.put(previous, :param_validation, :warn)
    )

    on_exit(fn -> Application.put_env(:zaq, Zaq.Engine.Workflows, previous) end)

    {:ok, workflow} =
      Workflows.create_workflow(%{
        name: "StepRunner param validation",
        status: "draft",
        steps: %{"nodes" => [], "edges" => []}
      })

    {:ok, run} =
      Workflows.create_run(workflow, %{
        "request" => nil,
        "assigns" => %{"trigger_type" => "manual"},
        "trace_id" => Ecto.UUID.generate()
      })

    %{run: run}
  end

  defp typed_params(run, params) do
    Map.merge(
      %{
        wrapped_module: TypedParamAction,
        run_id: run.id,
        step_name: "typed",
        step_index: 0
      },
      params
    )
  end

  test "a wrong-typed param logs the violation and the step still runs", %{run: run} do
    log =
      capture_log(fn ->
        assert {:ok, _} = StepRunner.run(typed_params(run, %{count: "42"}), %{})
      end)

    assert log =~ "Invalid parameters"
    assert log =~ "count: expected integer, got string"
    assert_received {:typed_param_action_ran, _}

    [step_run] = Workflows.list_step_runs(run.id)
    assert step_run.status == "completed"
  end

  test "a correctly-typed param logs nothing", %{run: run} do
    log =
      capture_log(fn ->
        assert {:ok, _} = StepRunner.run(typed_params(run, %{count: 42}), %{})
      end)

    refute log =~ "Invalid parameters"
  end
end
