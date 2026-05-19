defmodule Zaq.Engine.Workflows.ActionWrapperTest do
  use Zaq.DataCase, async: true

  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.ActionWrapper
  alias Zaq.Engine.Workflows.Conditions.ConditionNotMet
  alias Zaq.Engine.Workflows.Test.{ErrorAction, OkAction, OkWithLogsAction}

  @valid_workflow_attrs %{
    name: "ActionWrapper Test Workflow",
    status: "draft",
    steps: %{"nodes" => [], "edges" => []}
  }

  @valid_source_event %{
    "request" => nil,
    "assigns" => %{"trigger_type" => "manual"},
    "trace_id" => Ecto.UUID.generate()
  }

  defp create_run do
    {:ok, wf} = Workflows.create_workflow(@valid_workflow_attrs)
    {:ok, run} = Workflows.create_run(wf, @valid_source_event)
    run
  end

  defp wp(run, mod, step_name, step_index) do
    %{wrapped_module: mod, run_id: run.id, step_name: step_name, step_index: step_index}
  end

  describe "run/2 — happy path" do
    test "calls wrapped module and writes completed ActionResult" do
      run = create_run()

      assert {:ok, %{value: "done"}} = ActionWrapper.run(wp(run, OkAction, "fetch", 0), %{})

      [ar] = Workflows.list_step_runs(run.id)
      assert ar.step_name == "fetch"
      assert ar.step_index == 0
      assert ar.status == "completed"
      assert ar.results == %{"value" => "done"}
      assert ar.finished_at != nil
    end

    test "result passes through unchanged" do
      run = create_run()

      assert {:ok, result} = ActionWrapper.run(wp(run, OkAction, "step", 1), %{})
      assert result == %{value: "done"}
    end

    test "extra fields in params reach the wrapped module without error" do
      run = create_run()
      params = wp(run, OkAction, "step", 0) |> Map.put(:extra, "value")

      assert {:ok, _} = ActionWrapper.run(params, %{})
    end

    test "calls wrapped module returning 3-tuple with logs and writes completed StepRun" do
      run = create_run()

      assert {:ok, %{value: "with_logs"}} =
               ActionWrapper.run(wp(run, OkWithLogsAction, "fetch_logs", 0), %{})

      [ar] = Workflows.list_step_runs(run.id)
      assert ar.status == "completed"
      assert ar.results == %{"value" => "with_logs"}
      assert ar.finished_at != nil
    end
  end

  describe "run/2 — error path" do
    test "calls wrapped module and writes failed ActionResult" do
      run = create_run()

      assert {:error, :test_failure} = ActionWrapper.run(wp(run, ErrorAction, "draft", 1), %{})

      [ar] = Workflows.list_step_runs(run.id)
      assert ar.status == "failed"
      assert ar.errors["reason"] =~ "test_failure"
      assert ar.finished_at != nil
    end

    test "error from wrapped module passes through unchanged" do
      run = create_run()

      assert {:error, :test_failure} = ActionWrapper.run(wp(run, ErrorAction, "step", 0), %{})
    end
  end

  describe "run/2 — wrapper fields are stripped from ActionResult results" do
    test "wrapper keys do not appear in completed results" do
      run = create_run()
      ActionWrapper.run(wp(run, OkAction, "fetch", 0), %{})

      [ar] = Workflows.list_step_runs(run.id)
      refute Map.has_key?(ar.results || %{}, "wrapped_module")
      refute Map.has_key?(ar.results || %{}, "run_id")
    end
  end

  describe "run/2 — crash safety" do
    test "StepRun row is marked failed and exception is re-raised when wrapped module raises" do
      defmodule RaisingAction do
        @moduledoc false
        use Jido.Action, name: "raising_test_action_aw", schema: []
        def run(_params, _context), do: raise("boom")
      end

      run = create_run()

      assert_raise RuntimeError, "boom", fn ->
        ActionWrapper.run(wp(run, RaisingAction, "step", 0), %{})
      end

      [ar] = Workflows.list_step_runs(run.id)
      assert ar.status == "failed"
      assert ar.errors["reason"] =~ "boom"
      assert ar.finished_at != nil
    end
  end

  describe "run/2 — ConditionNotMet rescue" do
    test "StepRun is marked skipped, ConditionNotMet is re-raised" do
      defmodule ConditionRaisingAction do
        @moduledoc false
        use Jido.Action, name: "condition_raising_test_action_aw", schema: []

        def run(_params, _context) do
          raise Zaq.Engine.Workflows.Conditions.ConditionNotMet,
            condition_name: "test_cond",
            field: "status",
            op: "eq",
            actual: "open",
            expected: "closed"
        end
      end

      run = create_run()

      assert_raise ConditionNotMet, fn ->
        ActionWrapper.run(wp(run, ConditionRaisingAction, "cond_step", 0), %{})
      end

      [ar] = Workflows.list_step_runs(run.id)
      assert ar.status == "skipped"
      assert ar.results["field"] == "status"
      assert ar.results["op"] == "eq"
      assert ar.finished_at != nil
    end
  end
end
