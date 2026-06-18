defmodule Zaq.Engine.Workflows.WorkflowsCoreTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties

  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.Step.Run, as: StepRun
  alias Zaq.Engine.Workflows.{StepApproval, Trigger, Workflow, WorkflowRun}
  alias Zaq.Test.Stubs

  @ok_module "Zaq.Engine.Workflows.Test.OkAction"

  setup do
    Stubs.stub_node_router()
    :ok
  end

  @valid_node %{
    name: "fetch",
    type: "action",
    module: "Zaq.Agent.Tools.Email.FetchEmails",
    params: %{},
    index: 0
  }

  @valid_workflow_attrs %{
    name: "Test Workflow",
    status: "draft"
  }

  @valid_active_attrs %{
    name: "Test Workflow",
    status: "active",
    nodes: [@valid_node],
    edges: []
  }

  @valid_source_event %{
    "request" => nil,
    "assigns" => %{"trigger_type" => "manual"},
    "trace_id" => Ecto.UUID.generate()
  }

  defp create_workflow(attrs \\ %{}) do
    {:ok, workflow} = Workflows.create_workflow(Map.merge(@valid_workflow_attrs, attrs))
    workflow
  end

  defp create_run(workflow, source_event \\ @valid_source_event) do
    {:ok, run} = Workflows.create_run(workflow, source_event)
    run
  end

  # --- Workflow CRUD ---

  describe "create_workflow/2" do
    test "creates a workflow with valid attrs" do
      assert {:ok, %Workflow{} = w} = Workflows.create_workflow(@valid_workflow_attrs)
      assert w.name == "Test Workflow"
      assert w.status == "draft"
    end

    test "returns error on missing name" do
      assert {:error, changeset} = Workflows.create_workflow(%{status: "draft"})
      assert changeset.errors[:name]
    end

    test "returns error on invalid status" do
      assert {:error, changeset} =
               Workflows.create_workflow(Map.put(@valid_workflow_attrs, :status, "unknown"))

      assert changeset.errors[:status]
    end

    test "dispatches workflow.created event on success" do
      test_pid = self()

      stub(Zaq.NodeRouterMock, :dispatch, fn event ->
        send(test_pid, {:dispatched, event})
        event
      end)

      assert {:ok, wf} = Workflows.create_workflow(@valid_workflow_attrs)

      assert_received {:dispatched, event}
      assert event.request[:action] == "workflow.created"
      assert event.request[:workflow_id] == wf.id
      assert event.name == :workflow
    end

    test "does not dispatch on invalid changeset" do
      test_pid = self()

      stub(Zaq.NodeRouterMock, :dispatch, fn event ->
        send(test_pid, {:dispatched, event})
        event
      end)

      assert {:error, _} = Workflows.create_workflow(%{status: "draft"})

      refute_received {:dispatched, _}
    end
  end

  describe "list_workflows/1" do
    test "returns all workflows ordered by name" do
      create_workflow(%{name: "Zeta"})
      create_workflow(%{name: "Alpha"})

      names = Workflows.list_workflows() |> Enum.map(& &1.name)
      assert names == Enum.sort(names)
    end
  end

  describe "get_workflow!/1" do
    test "returns workflow by id" do
      workflow = create_workflow()
      assert Workflows.get_workflow!(workflow.id).id == workflow.id
    end

    test "raises when not found" do
      assert_raise Ecto.NoResultsError, fn ->
        Workflows.get_workflow!(Ecto.UUID.generate())
      end
    end
  end

  describe "update_workflow/3" do
    test "updates fields" do
      workflow = create_workflow()
      assert {:ok, updated} = Workflows.update_workflow(workflow, %{name: "Renamed"})
      assert updated.name == "Renamed"
    end

    test "returns error on invalid status" do
      workflow = create_workflow()
      assert {:error, changeset} = Workflows.update_workflow(workflow, %{status: "invalid"})
      assert changeset.errors[:status]
    end
  end

  describe "archive_workflow/2" do
    test "sets status to archived" do
      {:ok, workflow} = Workflows.create_workflow(@valid_active_attrs)
      assert {:ok, archived} = Workflows.archive_workflow(workflow)
      assert archived.status == "archived"
    end
  end

  # --- Run lifecycle ---

  describe "create_run/4" do
    test "creates a run with steps and settings snapshotted from the workflow" do
      {:ok, workflow} = Workflows.create_workflow(@valid_active_attrs)
      assert {:ok, %WorkflowRun{} = run} = Workflows.create_run(workflow, @valid_source_event)

      assert run.workflow_id == workflow.id
      assert run.steps_snapshot["nodes"] != nil
      assert run.steps_snapshot["edges"] != nil
      assert run.settings_snapshot == workflow.settings
      assert run.status == "pending"
      assert run.source_event.trace_id == @valid_source_event["trace_id"]
    end

    test "broadcasts run_created for a pending run" do
      {:ok, workflow} = Workflows.create_workflow(@valid_active_attrs)
      Phoenix.PubSub.subscribe(Zaq.PubSub, "workflow:#{workflow.id}")

      assert {:ok, %WorkflowRun{} = run} = Workflows.create_run(workflow, @valid_source_event)

      assert_receive {:run_created, ^run}
      refute_received {:run_started, ^run}
    end

    test "does not execute steps" do
      {:ok, workflow} =
        Workflows.create_workflow(%{
          name: "Pending Run #{System.unique_integer()}",
          status: "active",
          nodes: [%{name: "step", type: "action", module: @ok_module, params: %{}, index: 0}],
          edges: []
        })

      assert {:ok, %WorkflowRun{} = run} = Workflows.create_run(workflow, @valid_source_event)

      assert run.status == "pending"
      assert Workflows.list_step_runs(run.id) == []
    end

    test "snapshot isolation: editing workflow after run start does not mutate the snapshot" do
      {:ok, workflow} = Workflows.create_workflow(@valid_active_attrs)
      run = create_run(workflow)

      original_snapshot = run.steps_snapshot

      {:ok, _} = Workflows.update_workflow(workflow, %{nodes: [], edges: [], status: "draft"})

      reloaded_run = Workflows.get_run!(run.id)
      assert reloaded_run.steps_snapshot == original_snapshot
    end
  end

  describe "broadcast_run_update/1" do
    test "re-broadcasts the current run to its workflow_run topic" do
      {:ok, workflow} = Workflows.create_workflow(@valid_active_attrs)
      run = create_run(workflow)
      Phoenix.PubSub.subscribe(Zaq.PubSub, "workflow_run:#{run.id}")

      assert :ok = Workflows.broadcast_run_update(run.id)
      assert_receive {:run_updated, %WorkflowRun{id: run_id}}
      assert run_id == run.id
    end

    test "no-ops when the run does not exist" do
      missing_id = Ecto.UUID.generate()
      Phoenix.PubSub.subscribe(Zaq.PubSub, "workflow_run:#{missing_id}")

      assert :ok = Workflows.broadcast_run_update(missing_id)
      refute_receive {:run_updated, _}
    end
  end

  describe "start_run/2" do
    test "executes a pending run and writes step rows" do
      {:ok, workflow} =
        Workflows.create_workflow(%{
          name: "Start Run #{System.unique_integer()}",
          status: "active",
          nodes: [%{name: "step", type: "action", module: @ok_module, params: %{}, index: 0}],
          edges: []
        })

      {:ok, run} = Workflows.create_run(workflow, @valid_source_event)

      assert {:ok, %WorkflowRun{} = finished} = Workflows.start_run(run)
      assert finished.status == "completed"

      assert [%StepRun{step_name: "step", status: "completed"}] =
               Workflows.list_step_runs(run.id)
    end

    test "rejects non-pending runs" do
      {:ok, workflow} = Workflows.create_workflow(@valid_active_attrs)
      {:ok, run} = Workflows.create_run(workflow, @valid_source_event)
      {:ok, running} = Workflows.update_run(run, %{status: "running"})

      assert {:error, {:invalid_run_status, "running"}} = Workflows.start_run(running)
    end
  end

  describe "create_and_start_run/4" do
    test "creates and executes a run" do
      {:ok, workflow} =
        Workflows.create_workflow(%{
          name: "Create And Start #{System.unique_integer()}",
          status: "active",
          nodes: [%{name: "step", type: "action", module: @ok_module, params: %{}, index: 0}],
          edges: []
        })

      assert {:ok, %WorkflowRun{} = finished} =
               Workflows.create_and_start_run(workflow, @valid_source_event)

      assert finished.status == "completed"

      assert [%StepRun{step_name: "step", status: "completed"}] =
               Workflows.list_step_runs(finished.id)
    end
  end

  describe "list_runs/2" do
    test "returns runs for workflow" do
      workflow = create_workflow()
      run1 = create_run(workflow)
      run2 = create_run(workflow)

      ids = Workflows.list_runs(workflow.id) |> Enum.map(& &1.id) |> MapSet.new()
      assert MapSet.equal?(ids, MapSet.new([run1.id, run2.id]))
    end

    test "returns empty list for workflow with no runs" do
      workflow = create_workflow()
      assert Workflows.list_runs(workflow.id) == []
    end
  end

  describe "update_run/3" do
    test "updates run status and started_at" do
      workflow = create_workflow()
      run = create_run(workflow)
      now = DateTime.utc_now(:second)

      assert {:ok, updated} =
               Workflows.update_run(run, %{status: "running", started_at: now})

      assert updated.status == "running"
      assert updated.started_at == now
    end
  end

  # --- Action results ---

  describe "create_step_run/3" do
    test "inserts a :running row before step executes" do
      workflow = create_workflow()
      run = create_run(workflow)

      assert {:ok, %StepRun{} = ar} =
               Workflows.create_step_run(run, %{
                 step_name: "fetch_data",
                 step_index: 0,
                 status: "running",
                 started_at: DateTime.utc_now(:second)
               })

      assert ar.workflow_run_id == run.id
      assert ar.step_name == "fetch_data"
      assert ar.step_index == 0
      assert ar.status == "running"
    end
  end

  describe "create_step_run/3 — started_at default" do
    test "sets started_at automatically when not provided" do
      workflow = create_workflow()
      run = create_run(workflow)

      {:ok, ar} = Workflows.create_step_run(run, %{step_name: "s", step_index: 0})
      assert ar.started_at != nil
    end

    test "preserves caller-supplied started_at" do
      workflow = create_workflow()
      run = create_run(workflow)
      explicit = ~U[2025-01-01 00:00:00Z]

      {:ok, ar} =
        Workflows.create_step_run(run, %{step_name: "s", step_index: 0, started_at: explicit})

      assert ar.started_at == explicit
    end
  end

  describe "complete_step_run/3" do
    test "sets status completed, writes results and finished_at" do
      workflow = create_workflow()
      run = create_run(workflow)
      {:ok, ar} = Workflows.create_step_run(run, %{step_name: "s", step_index: 0})

      result_map = %{"output" => "ok"}
      assert {:ok, completed} = Workflows.complete_step_run(ar, result_map)

      assert completed.status == "completed"
      assert completed.results == result_map
      assert completed.finished_at != nil
      assert completed.errors == nil
    end
  end

  describe "fail_step_run/3" do
    test "sets status failed, writes errors and finished_at" do
      workflow = create_workflow()
      run = create_run(workflow)
      {:ok, ar} = Workflows.create_step_run(run, %{step_name: "s", step_index: 0})

      error_map = %{"reason" => "timeout"}
      assert {:ok, failed} = Workflows.fail_step_run(ar, error_map)

      assert failed.status == "failed"
      assert failed.errors == error_map
      assert failed.finished_at != nil
      assert failed.results == nil
    end
  end

  describe "list_step_runs/2" do
    test "returns rows ordered by step_index ascending" do
      workflow = create_workflow()
      run = create_run(workflow)

      {:ok, _} = Workflows.create_step_run(run, %{step_name: "c", step_index: 2})
      {:ok, _} = Workflows.create_step_run(run, %{step_name: "a", step_index: 0})
      {:ok, _} = Workflows.create_step_run(run, %{step_name: "b", step_index: 1})

      results = Workflows.list_step_runs(run.id)
      assert Enum.map(results, & &1.step_index) == [0, 1, 2]
    end

    test "rehydration: completed rows rebuild previous_results, last running row is cursor" do
      workflow = create_workflow()
      run = create_run(workflow)

      {:ok, ar0} = Workflows.create_step_run(run, %{step_name: "fetch", step_index: 0})
      {:ok, _} = Workflows.complete_step_run(ar0, %{"data" => "fetched"})

      {:ok, ar1} = Workflows.create_step_run(run, %{step_name: "process", step_index: 1})
      {:ok, _} = Workflows.complete_step_run(ar1, %{"result" => "done"})

      # Simulate crash mid-step 2
      {:ok, _ar2} = Workflows.create_step_run(run, %{step_name: "notify", step_index: 2})

      all = Workflows.list_step_runs(run.id)

      previous_results =
        all
        |> Enum.filter(&(&1.status == "completed"))
        |> Map.new(&{&1.step_name, &1.results})

      resume_cursor = all |> Enum.filter(&(&1.status == "running")) |> List.last()

      assert previous_results == %{
               "fetch" => %{"data" => "fetched"},
               "process" => %{"result" => "done"}
             }

      assert resume_cursor.step_name == "notify"
      assert resume_cursor.step_index == 2
    end
  end

  # --- Property tests ---

  describe "list_step_runs/1 — ordering invariant" do
    property "always returns step runs sorted by step_index ascending regardless of insertion order" do
      check all(indices <- uniq_list_of(integer(0..99), min_length: 1, max_length: 10)) do
        workflow = create_workflow()
        run = create_run(workflow)

        indices
        |> Enum.shuffle()
        |> Enum.each(fn idx ->
          {:ok, _} = Workflows.create_step_run(run, %{step_name: "step_#{idx}", step_index: idx})
        end)

        result = Workflows.list_step_runs(run.id)
        assert Enum.map(result, & &1.step_index) == Enum.sort(indices)
      end
    end
  end

  # --- Trace ---

  describe "get_run_trace/1" do
    test "returns run-level fields" do
      workflow = create_workflow(%{name: "Trace Test"})
      run = create_run(workflow)

      {:ok, _} =
        Workflows.update_run(run, %{
          status: "completed",
          started_at: ~U[2025-01-01 10:00:00Z],
          finished_at: ~U[2025-01-01 10:00:05Z]
        })

      trace = Workflows.get_run_trace(run.id)

      assert trace.run_id == run.id
      assert trace.workflow_id == workflow.id
      assert trace.workflow_name == "Trace Test"
      assert trace.status == "completed"
      assert trace.duration_ms == 5_000
    end

    test "includes ordered step runs with durations and errors" do
      workflow = create_workflow()
      run = create_run(workflow)

      {:ok, sr0} =
        Workflows.create_step_run(run, %{
          step_name: "fetch",
          step_index: 0,
          started_at: ~U[2025-01-01 10:00:00Z]
        })

      {:ok, _} = Workflows.complete_step_run(sr0, %{"data" => "ok"})
      {:ok, _} = Workflows.update_run(run, %{})

      # manually set finished_at for the step run via update
      Zaq.Repo.update!(Ecto.Changeset.change(sr0, finished_at: ~U[2025-01-01 10:00:02Z]))

      {:ok, sr1} = Workflows.create_step_run(run, %{step_name: "process", step_index: 1})
      {:ok, _} = Workflows.fail_step_run(sr1, %{"reason" => "timeout"})

      trace = Workflows.get_run_trace(run.id)

      assert length(trace.steps) == 2

      [s0, s1] = trace.steps
      assert s0.step_name == "fetch"
      assert s0.step_index == 0
      assert s0.status == "completed"
      assert s0.results == %{"data" => "ok"}
      assert s0.errors == nil

      assert s1.step_name == "process"
      assert s1.step_index == 1
      assert s1.status == "failed"
      assert s1.errors == %{"reason" => "timeout"}
      assert s1.results == nil
    end

    test "returns empty steps list when run has no step runs" do
      workflow = create_workflow()
      run = create_run(workflow)

      trace = Workflows.get_run_trace(run.id)
      assert trace.steps == []
    end

    test "duration_ms is nil when run has not started or finished" do
      workflow = create_workflow()
      run = create_run(workflow)

      trace = Workflows.get_run_trace(run.id)
      assert trace.duration_ms == nil
    end

    test "duration_ms is nil when run has started but not yet finished (line 756)" do
      # started_at is set, finished_at is nil → duration_ms(started_at, nil) → nil (line 756)
      workflow = create_workflow()
      run = create_run(workflow)

      {:ok, running} =
        Workflows.update_run(run, %{status: "running", started_at: DateTime.utc_now(:second)})

      trace = Workflows.get_run_trace(running.id)
      assert is_nil(trace.duration_ms)
      assert not is_nil(trace.started_at)
      assert is_nil(trace.finished_at)
    end
  end

  # --- Triggers ---

  # --- Schema accessors ---

  describe "Workflow.statuses/0" do
    test "returns the expected status list" do
      assert Workflow.statuses() == ~w(draft active archived)
    end
  end

  describe "WorkflowRun.statuses/0" do
    test "returns the expected status list" do
      assert WorkflowRun.statuses() ==
               ~w(pending running waiting paused completed failed cancelled interrupted)
    end
  end

  describe "StepRun.statuses/0" do
    test "returns the expected status list" do
      assert StepRun.statuses() == ~w(running paused waiting completed failed skipped)
    end
  end

  # --- Triggers ---

  describe "create_trigger/2" do
    test "creates a trigger with event_name" do
      assert {:ok, %Trigger{} = t} =
               Workflows.create_trigger(%{
                 event_name: "manual_trigger",
                 enabled: true
               })

      assert t.event_name == "engine:manual_trigger"
      assert t.enabled == true
    end

    test "returns error without event_name" do
      assert {:error, changeset} = Workflows.create_trigger(%{})
      assert changeset.errors[:event_name]
    end
  end

  describe "list_triggers/0" do
    test "returns all triggers" do
      {:ok, _} = Workflows.create_trigger(%{event_name: "event_a"})
      {:ok, _} = Workflows.create_trigger(%{event_name: "event_b"})

      assert length(Workflows.list_triggers()) >= 2
    end
  end

  describe "update_trigger/3" do
    test "updates trigger fields" do
      {:ok, trigger} = Workflows.create_trigger(%{event_name: "some_event"})

      assert {:ok, updated} = Workflows.update_trigger(trigger, %{enabled: false})

      assert updated.enabled == false
    end

    test "returns error with blank event_name" do
      {:ok, trigger} = Workflows.create_trigger(%{event_name: "some_event"})

      assert {:error, changeset} = Workflows.update_trigger(trigger, %{event_name: ""})
      assert changeset.errors[:event_name]
    end
  end

  # --- pause_run/2 ---

  describe "pause_run/2" do
    test "transitions a running run to paused" do
      wf = create_workflow(@valid_active_attrs)
      run = create_run(wf)
      {:ok, running} = Workflows.update_run(run, %{status: "running"})

      assert {:ok, paused} = Workflows.pause_run(running)
      assert paused.status == "paused"
    end

    test "returns :not_running for a pending run" do
      wf = create_workflow(@valid_active_attrs)
      run = create_run(wf)
      assert run.status == "pending"

      assert {:error, :not_running} = Workflows.pause_run(run)
    end

    test "returns :not_running for an already completed run" do
      wf = create_workflow(@valid_active_attrs)
      run = create_run(wf)
      {:ok, completed} = Workflows.update_run(run, %{status: "completed"})

      assert {:error, :not_running} = Workflows.pause_run(completed)
    end

    test "returns :not_running for a failed run" do
      wf = create_workflow(@valid_active_attrs)
      run = create_run(wf)
      {:ok, failed} = Workflows.update_run(run, %{status: "failed"})

      assert {:error, :not_running} = Workflows.pause_run(failed)
    end

    test "marks in-flight step runs as paused" do
      wf = create_workflow(@valid_active_attrs)
      run = create_run(wf)
      {:ok, running} = Workflows.update_run(run, %{status: "running"})

      {:ok, _sr} =
        Workflows.create_step_run(run, %{step_name: "fetch", step_index: 0, status: "running"})

      assert {:ok, paused} = Workflows.pause_run(running)
      assert paused.status == "paused"

      [step_run] = Workflows.list_step_runs(run.id)
      assert step_run.status == "paused"
    end
  end

  # --- resume_run/2 ---

  describe "resume_run/2" do
    test "returns :not_paused for a pending run" do
      wf = create_workflow(@valid_active_attrs)
      run = create_run(wf)

      assert {:error, :not_paused} = Workflows.resume_run(run)
    end

    test "returns :not_paused for a running run" do
      wf = create_workflow(@valid_active_attrs)
      run = create_run(wf)
      {:ok, running} = Workflows.update_run(run, %{status: "running"})

      assert {:error, :not_paused} = Workflows.resume_run(running)
    end

    test "returns :not_paused for a completed run" do
      wf = create_workflow(@valid_active_attrs)
      run = create_run(wf)
      {:ok, completed} = Workflows.update_run(run, %{status: "completed"})

      assert {:error, :not_paused} = Workflows.resume_run(completed)
    end
  end

  # --- get_completed_step_run/2 ---

  describe "get_completed_step_run/2" do
    test "returns the completed StepRun when it exists" do
      wf = create_workflow(@valid_active_attrs)
      run = create_run(wf)

      {:ok, sr} =
        Workflows.create_step_run(run, %{step_name: "fetch", step_index: 0, status: "running"})

      {:ok, _} = Workflows.complete_step_run(sr, %{value: "done"})

      result = Workflows.get_completed_step_run(run.id, "fetch")
      assert %StepRun{} = result
      assert result.status == "completed"
      assert result.step_name == "fetch"
    end

    test "returns nil when no completed step exists for that step_name" do
      wf = create_workflow(@valid_active_attrs)
      run = create_run(wf)

      assert nil == Workflows.get_completed_step_run(run.id, "fetch")
    end

    test "returns nil when step exists but is not completed" do
      wf = create_workflow(@valid_active_attrs)
      run = create_run(wf)

      {:ok, _} =
        Workflows.create_step_run(run, %{step_name: "fetch", step_index: 0, status: "running"})

      assert nil == Workflows.get_completed_step_run(run.id, "fetch")
    end
  end

  describe "get_terminal_step_run/2" do
    test "returns a completed StepRun" do
      wf = create_workflow(@valid_active_attrs)
      run = create_run(wf)

      {:ok, sr} =
        Workflows.create_step_run(run, %{step_name: "fetch", step_index: 0, status: "running"})

      {:ok, _} = Workflows.complete_step_run(sr, %{value: "done"})

      result = Workflows.get_terminal_step_run(run.id, "fetch")
      assert %StepRun{status: "completed"} = result
    end

    test "returns a failed StepRun" do
      wf = create_workflow(@valid_active_attrs)
      run = create_run(wf)

      {:ok, sr} =
        Workflows.create_step_run(run, %{step_name: "draft", step_index: 1, status: "running"})

      {:ok, _} = Workflows.fail_step_run(sr, %{reason: "boom"})

      result = Workflows.get_terminal_step_run(run.id, "draft")
      assert %StepRun{status: "failed"} = result
    end

    test "returns a skipped StepRun" do
      wf = create_workflow(@valid_active_attrs)
      run = create_run(wf)

      {:ok, sr} =
        Workflows.create_step_run(run, %{step_name: "edge", step_index: 0, status: "running"})

      {:ok, _} = Workflows.skip_step_run(sr, %{field: "count", op: "gt", actual: 0, expected: 1})

      result = Workflows.get_terminal_step_run(run.id, "edge")
      assert %StepRun{status: "skipped"} = result
    end

    test "returns a waiting StepRun" do
      wf = create_workflow(@valid_active_attrs)
      run = create_run(wf)

      {:ok, sr} =
        Workflows.create_step_run(run, %{step_name: "hitl", step_index: 1, status: "running"})

      {:ok, _} = Workflows.wait_step_run(sr)

      result = Workflows.get_terminal_step_run(run.id, "hitl")
      assert %StepRun{status: "waiting"} = result
    end

    test "returns nil when no terminal step run exists" do
      wf = create_workflow(@valid_active_attrs)
      run = create_run(wf)

      assert nil == Workflows.get_terminal_step_run(run.id, "fetch")
    end

    test "returns nil when step is running (not yet terminal)" do
      wf = create_workflow(@valid_active_attrs)
      run = create_run(wf)

      {:ok, _} =
        Workflows.create_step_run(run, %{step_name: "fetch", step_index: 0, status: "running"})

      assert nil == Workflows.get_terminal_step_run(run.id, "fetch")
    end

    test "does not raise when multiple terminal rows exist for the same step" do
      wf = create_workflow(@valid_active_attrs)
      run = create_run(wf)

      {:ok, sr1} =
        Workflows.create_step_run(run, %{step_name: "draft", step_index: 0, status: "running"})

      {:ok, _} = Workflows.fail_step_run(sr1, %{reason: "first attempt"})

      {:ok, sr2} =
        Workflows.create_step_run(run, %{step_name: "draft", step_index: 0, status: "running"})

      {:ok, _} = Workflows.fail_step_run(sr2, %{reason: "second attempt"})

      result = Workflows.get_terminal_step_run(run.id, "draft")
      assert %StepRun{status: "failed"} = result
    end
  end

  # ---------------------------------------------------------------------------
  # Human-in-the-loop: approval CRUD and lifecycle
  # ---------------------------------------------------------------------------

  @hitl_module "Zaq.Engine.Workflows.Steps.HumanInTheLoop"
  @hitl_node %{
    name: "hitl",
    type: "action",
    module: @hitl_module,
    params: %{"message" => "Review me"},
    index: 1
  }
  @after_hitl_node %{
    name: "after",
    type: "action",
    module: "Zaq.Engine.Workflows.Test.OkAction",
    params: %{},
    index: 2
  }

  defp hitl_workflow do
    {:ok, wf} =
      Workflows.create_workflow(%{
        name: "hitl-wf-#{System.unique_integer()}",
        status: "active",
        nodes: [
          %{
            name: "step0",
            type: "action",
            module: "Zaq.Engine.Workflows.Test.OkAction",
            params: %{},
            index: 0
          },
          @hitl_node,
          @after_hitl_node
        ],
        edges: [
          %{from: "step0", to: "hitl"},
          %{from: "hitl", to: "after"}
        ]
      })

    wf
  end

  describe "create_approval/2" do
    test "creates an approval record with pending status" do
      run = create_run(create_workflow())
      {:ok, run} = Workflows.update_run(run, %{status: "waiting"})

      {:ok, approval} =
        Workflows.create_approval(%{
          workflow_run_id: run.id,
          step_name: "hitl",
          approval_token: Ecto.UUID.generate(),
          message: "Please review",
          status: "pending"
        })

      assert approval.status == "pending"
      assert approval.workflow_run_id == run.id
    end

    test "returns error on duplicate (run_id, step_name)" do
      run = create_run(create_workflow())
      {:ok, run} = Workflows.update_run(run, %{status: "waiting"})
      token1 = Ecto.UUID.generate()

      {:ok, _} =
        Workflows.create_approval(%{
          workflow_run_id: run.id,
          step_name: "hitl",
          approval_token: token1,
          status: "pending"
        })

      assert {:error, _changeset} =
               Workflows.create_approval(%{
                 workflow_run_id: run.id,
                 step_name: "hitl",
                 approval_token: Ecto.UUID.generate(),
                 status: "pending"
               })
    end
  end

  describe "get_approval_by_token/2" do
    test "returns the approval matching the token" do
      run = create_run(create_workflow())
      {:ok, run} = Workflows.update_run(run, %{status: "waiting"})
      token = Ecto.UUID.generate()

      {:ok, approval} =
        Workflows.create_approval(%{
          workflow_run_id: run.id,
          step_name: "hitl",
          approval_token: token,
          status: "pending"
        })

      assert %StepApproval{} = found = Workflows.get_approval_by_token(token)
      assert found.id == approval.id
    end

    test "returns nil when token does not exist" do
      assert nil == Workflows.get_approval_by_token(Ecto.UUID.generate())
    end
  end

  describe "approve_step/5" do
    test "returns {:error, :not_waiting} when run is not in waiting state" do
      wf = hitl_workflow()
      run = create_run(wf)

      {:ok, approval} =
        Workflows.create_approval(%{
          workflow_run_id: run.id,
          step_name: "hitl",
          approval_token: Ecto.UUID.generate(),
          status: "pending"
        })

      assert {:error, :not_waiting} =
               Workflows.approve_step(run, approval, %{ok: true}, nil)
    end

    test "returns {:error, :already_decided} when approval is not pending" do
      wf = hitl_workflow()
      run = create_run(wf)
      {:ok, run} = Workflows.update_run(run, %{status: "waiting"})

      {:ok, approval} =
        Workflows.create_approval(%{
          workflow_run_id: run.id,
          step_name: "hitl",
          approval_token: Ecto.UUID.generate(),
          status: "approved"
        })

      assert {:error, :already_decided} =
               Workflows.approve_step(run, approval, %{ok: true}, nil)
    end

    test "full E2E: suspend → approve → run completes, downstream step executed" do
      wf = hitl_workflow()
      {:ok, run} = Workflows.create_run(wf, @valid_source_event)
      {:ok, waiting_run} = Workflows.start_run(run)
      assert waiting_run.status == "waiting"

      approval = Workflows.get_pending_approval(run.id)
      assert approval != nil
      assert approval.status == "pending"

      {:ok, completed_run} =
        Workflows.approve_step(waiting_run, approval, %{note: "LGTM"}, "approver-1")

      assert completed_run.status == "completed"

      step_runs = Workflows.list_step_runs(run.id)
      by_name = Map.new(step_runs, &{&1.step_name, &1})

      assert by_name["step0"].status == "completed"
      assert by_name["hitl"].status == "completed"
      assert by_name["hitl"].results["approved"] == true
      assert by_name["hitl"].results["approved_by"] == "approver-1"
      assert by_name["after"].status == "completed"
    end

    test "complete_waiting_step no-ops when step_name has no waiting StepRun (line 608)" do
      # Approval step_name has no matching "waiting" StepRun → complete_waiting_step returns :ok.
      # Uses OkAction so resume_run completes cleanly without external dependencies.
      {:ok, wf} =
        Workflows.create_workflow(%{
          name: "ok-wf-#{System.unique_integer()}",
          status: "active",
          nodes: [
            %{
              name: "step0",
              type: "action",
              module: "Zaq.Engine.Workflows.Test.OkAction",
              params: %{},
              index: 0
            }
          ],
          edges: []
        })

      run = create_run(wf)
      {:ok, waiting_run} = Workflows.update_run(run, %{status: "waiting"})

      {:ok, approval} =
        Workflows.create_approval(%{
          workflow_run_id: run.id,
          step_name: "step_with_no_step_run",
          approval_token: Ecto.UUID.generate(),
          status: "pending"
        })

      assert {:ok, completed_run} = Workflows.approve_step(waiting_run, approval, %{}, nil)
      assert completed_run.status == "completed"
    end

    test "rebuild_cascade_before returns empty map when no prior completed steps (line 629)" do
      # Approval step at index 0: rebuild_cascade_before queries step_index < 0 → nothing → %{}
      {:ok, wf} =
        Workflows.create_workflow(%{
          name: "ok-wf-#{System.unique_integer()}",
          status: "active",
          nodes: [
            %{
              name: "step0",
              type: "action",
              module: "Zaq.Engine.Workflows.Test.OkAction",
              params: %{},
              index: 0
            }
          ],
          edges: []
        })

      run = create_run(wf)
      {:ok, waiting_run} = Workflows.update_run(run, %{status: "waiting"})

      {:ok, _} =
        Workflows.create_step_run(run, %{
          step_name: "step0",
          step_index: 0,
          status: "waiting"
        })

      {:ok, approval} =
        Workflows.create_approval(%{
          workflow_run_id: run.id,
          step_name: "step0",
          approval_token: Ecto.UUID.generate(),
          status: "pending"
        })

      # complete_waiting_step finds step_run at index 0 → rebuild_cascade_before(run.id, 0)
      # queries index < 0 → nil → `_ -> %{}` (line 629)
      assert {:ok, completed_run} = Workflows.approve_step(waiting_run, approval, %{}, nil)
      assert completed_run.status == "completed"
    end
  end

  describe "reject_step/5" do
    test "returns {:error, :not_waiting} when run is not waiting" do
      wf = hitl_workflow()
      run = create_run(wf)

      {:ok, approval} =
        Workflows.create_approval(%{
          workflow_run_id: run.id,
          step_name: "hitl",
          approval_token: Ecto.UUID.generate(),
          status: "pending"
        })

      assert {:error, :not_waiting} =
               Workflows.reject_step(run, approval, "nope", nil)
    end

    test "full E2E: suspend → reject → run fails, downstream step not executed" do
      wf = hitl_workflow()
      {:ok, run} = Workflows.create_run(wf, @valid_source_event)
      {:ok, waiting_run} = Workflows.start_run(run)
      assert waiting_run.status == "waiting"

      approval = Workflows.get_pending_approval(run.id)

      {:ok, failed_run} =
        Workflows.reject_step(waiting_run, approval, "Not approved", "approver-1")

      assert failed_run.status == "failed"

      step_runs = Workflows.list_step_runs(run.id)
      by_name = Map.new(step_runs, &{&1.step_name, &1})

      assert by_name["hitl"].status == "failed"
      assert by_name["hitl"].errors["rejected"] == true
      refute Map.has_key?(by_name, "after")
    end

    test "populates log_summary with the rejection reason" do
      wf = hitl_workflow()
      {:ok, run} = Workflows.create_run(wf, @valid_source_event)
      {:ok, waiting_run} = Workflows.start_run(run)
      approval = Workflows.get_pending_approval(run.id)

      {:ok, _} = Workflows.reject_step(waiting_run, approval, "tone is wrong", "reviewer-1")

      reloaded = Workflows.get_run!(run.id)
      assert reloaded.log_summary["rejection_reason"] == "tone is wrong"
    end

    test "log_summary identifies the rejected step in failed_steps" do
      wf = hitl_workflow()
      {:ok, run} = Workflows.create_run(wf, @valid_source_event)
      {:ok, waiting_run} = Workflows.start_run(run)
      approval = Workflows.get_pending_approval(run.id)

      {:ok, _} = Workflows.reject_step(waiting_run, approval, "nope", nil)

      reloaded = Workflows.get_run!(run.id)
      assert reloaded.log_summary["failed_steps"] == ["hitl"]
      assert reloaded.log_summary["failed_step_count"] == 1
    end

    test "log_summary timeline includes all steps executed before rejection" do
      wf = hitl_workflow()
      {:ok, run} = Workflows.create_run(wf, @valid_source_event)
      {:ok, waiting_run} = Workflows.start_run(run)
      approval = Workflows.get_pending_approval(run.id)

      {:ok, _} = Workflows.reject_step(waiting_run, approval, "nope", nil)

      reloaded = Workflows.get_run!(run.id)
      timeline = reloaded.log_summary["timeline"]
      step_names = Enum.map(timeline, & &1["step_name"])

      assert "step0" in step_names
      assert "hitl" in step_names
      refute "after" in step_names
    end

    test "log_summary step_count matches the number of steps executed before rejection" do
      wf = hitl_workflow()
      {:ok, run} = Workflows.create_run(wf, @valid_source_event)
      {:ok, waiting_run} = Workflows.start_run(run)
      approval = Workflows.get_pending_approval(run.id)

      {:ok, _} = Workflows.reject_step(waiting_run, approval, "nope", nil)

      reloaded = Workflows.get_run!(run.id)
      step_runs = Workflows.list_step_runs(run.id)
      assert reloaded.log_summary["step_count"] == length(step_runs)
    end

    test "fail_waiting_step no-ops when step_name has no waiting StepRun (line 638)" do
      # Approval step_name has no matching "waiting" StepRun → fail_waiting_step returns :ok.
      # The rejection still marks the run as failed.
      {:ok, wf} =
        Workflows.create_workflow(%{
          name: "ok-wf-#{System.unique_integer()}",
          status: "active",
          nodes: [
            %{
              name: "step0",
              type: "action",
              module: "Zaq.Engine.Workflows.Test.OkAction",
              params: %{},
              index: 0
            }
          ],
          edges: []
        })

      run = create_run(wf)
      {:ok, waiting_run} = Workflows.update_run(run, %{status: "waiting"})

      {:ok, approval} =
        Workflows.create_approval(%{
          workflow_run_id: run.id,
          step_name: "step_with_no_step_run",
          approval_token: Ecto.UUID.generate(),
          status: "pending"
        })

      assert {:ok, failed_run} = Workflows.reject_step(waiting_run, approval, "denied", nil)
      assert failed_run.status == "failed"
    end
  end
end
