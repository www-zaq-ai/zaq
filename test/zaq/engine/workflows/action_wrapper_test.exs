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

      assert {:ok, _} = ActionWrapper.run(wp(run, OkAction, "fetch", 0), %{})

      [ar] = Workflows.list_step_runs(run.id)
      assert ar.step_name == "fetch"
      assert ar.step_index == 0
      assert ar.status == "completed"
      assert ar.results["value"] == "done"
      assert ar.finished_at != nil
    end

    test "result includes action output and updated cascade" do
      run = create_run()

      assert {:ok, result} = ActionWrapper.run(wp(run, OkAction, "step", 1), %{})
      assert result[:value] == "done"
      assert result[:__cascade__] == %{"step" => %{value: "done"}}
    end

    test "extra fields in params reach the wrapped module without error" do
      run = create_run()
      params = wp(run, OkAction, "step", 0) |> Map.put(:extra, "value")

      assert {:ok, _} = ActionWrapper.run(params, %{})
    end

    test "calls wrapped module returning 3-tuple with logs and writes completed StepRun" do
      run = create_run()

      assert {:ok, result} =
               ActionWrapper.run(wp(run, OkWithLogsAction, "fetch_logs", 0), %{})

      assert result[:value] == "with_logs"

      [ar] = Workflows.list_step_runs(run.id)
      assert ar.status == "completed"
      assert ar.results["value"] == "with_logs"
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

  describe "run/2 — resume idempotency (skip already-completed step)" do
    test "returns stored results without calling the wrapped module" do
      run = create_run()

      {:ok, sr} =
        Workflows.create_step_run(run, %{step_name: "fetch", step_index: 0, status: "running"})

      {:ok, _} = Workflows.complete_step_run(sr, %{cached: true})

      call_count = :counters.new(1, [])

      defmodule CountingAction do
        @moduledoc false
        use Jido.Action, name: "counting_action_aw", schema: []

        def run(_params, _context) do
          :counters.add(:persistent_term.get(:aw_counter), 1, 1)
          {:ok, %{called: true}}
        end
      end

      :persistent_term.put(:aw_counter, call_count)

      result = ActionWrapper.run(wp(run, CountingAction, "fetch", 0), %{})
      assert {:ok, %{"cached" => true}} = result
      assert :counters.get(call_count, 1) == 0, "wrapped module must not be called on resume"
    end

    test "does not insert a new StepRun row when step is already completed" do
      run = create_run()

      {:ok, sr} =
        Workflows.create_step_run(run, %{step_name: "fetch", step_index: 0, status: "running"})

      {:ok, _} = Workflows.complete_step_run(sr, %{value: "original"})

      ActionWrapper.run(wp(run, OkAction, "fetch", 0), %{})

      rows = Workflows.list_step_runs(run.id)
      assert length(rows) == 1, "must not create a duplicate StepRun on resume"
    end

    test "returns empty map when completed step has nil results" do
      run = create_run()

      {:ok, sr} =
        Workflows.create_step_run(run, %{step_name: "fetch", step_index: 0, status: "running"})

      Workflows.complete_step_run(sr, nil)

      assert {:ok, %{}} = ActionWrapper.run(wp(run, OkAction, "fetch", 0), %{})
    end

    test "runs normally when no completed StepRun exists" do
      run = create_run()
      assert {:ok, %{value: "done"}} = ActionWrapper.run(wp(run, OkAction, "fetch", 0), %{})

      [ar] = Workflows.list_step_runs(run.id)
      assert ar.status == "completed"
    end
  end

  describe "run/2 — cascade accumulation" do
    test "first step: no prior cascade → result contains cascade with this step only" do
      run = create_run()

      assert {:ok, result} = ActionWrapper.run(wp(run, OkAction, "step_a", 0), %{})
      assert result[:__cascade__] == %{"step_a" => %{value: "done"}}
    end

    test "second step: receives prior cascade → result extends it" do
      run = create_run()
      prior_cascade = %{"step_a" => %{value: "from_a"}}
      params = wp(run, OkAction, "step_b", 1) |> Map.put(:__cascade__, prior_cascade)

      assert {:ok, result} = ActionWrapper.run(params, %{})

      assert result[:__cascade__] == %{
               "step_a" => %{value: "from_a"},
               "step_b" => %{value: "done"}
             }
    end

    test "string-keyed __cascade__ (JSONB resume path) is read and extended" do
      run = create_run()
      prior_cascade = %{"step_a" => %{"value" => "from_a"}}
      params = wp(run, OkAction, "step_b", 1) |> Map.put("__cascade__", prior_cascade)

      assert {:ok, result} = ActionWrapper.run(params, %{})
      assert result[:__cascade__]["step_a"] == %{"value" => "from_a"}
      assert result[:__cascade__]["step_b"] == %{value: "done"}
    end

    test "failed step does not update the cascade" do
      run = create_run()
      prior_cascade = %{"step_a" => %{value: "from_a"}}
      params = wp(run, ErrorAction, "step_b", 1) |> Map.put(:__cascade__, prior_cascade)

      assert {:error, :test_failure} = ActionWrapper.run(params, %{})

      [ar] = Workflows.list_step_runs(run.id)
      assert ar.status == "failed"
      refute Map.has_key?(ar.errors || %{}, "__cascade__")
    end

    test "cascade is stored in StepRun results so resume recovers it" do
      run = create_run()
      prior_cascade = %{"step_a" => %{value: "from_a"}}
      params = wp(run, OkAction, "step_b", 1) |> Map.put(:__cascade__, prior_cascade)

      ActionWrapper.run(params, %{})

      [ar] = Workflows.list_step_runs(run.id)
      assert ar.results["__cascade__"]["step_a"] == %{"value" => "from_a"}
      assert ar.results["__cascade__"]["step_b"] == %{"value" => "done"}
    end

    test "wrapped module never sees __cascade__ in its params" do
      defmodule CascadeProbe do
        @moduledoc false
        use Jido.Action,
          name: "cascade_probe",
          schema: [input: [type: :any]],
          output_schema: [saw_cascade: [type: :boolean, required: true]]

        @behaviour Zaq.Engine.Workflows.Action
        @impl Zaq.Engine.Workflows.Action
        def on_success(result, _), do: {:ok, result}
        @impl Zaq.Engine.Workflows.Action
        def on_failure(_, _), do: :ok

        @impl true
        def run(params, _context) do
          saw = Map.has_key?(params, :__cascade__) or Map.has_key?(params, "__cascade__")
          {:ok, %{saw_cascade: saw}}
        end
      end

      run = create_run()
      params = wp(run, CascadeProbe, "probe", 0) |> Map.put(:__cascade__, %{"x" => %{v: 1}})

      assert {:ok, result} = ActionWrapper.run(params, %{})
      assert result[:saw_cascade] == false
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
