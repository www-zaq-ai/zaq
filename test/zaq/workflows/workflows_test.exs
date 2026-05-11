defmodule Zaq.WorkflowsTest do
  use Zaq.DataCase, async: true

  alias Zaq.Workflows
  alias Zaq.Workflows.{ActionResult, Trigger, Workflow, WorkflowRun}

  @valid_workflow_attrs %{
    name: "Test Workflow",
    status: "draft",
    steps: %{"step1" => %{"type" => "http_request"}}
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
      assert w.steps == %{"step1" => %{"type" => "http_request"}}
    end

    test "returns error on missing name" do
      assert {:error, changeset} = Workflows.create_workflow(%{status: "draft", steps: %{}})
      assert changeset.errors[:name]
    end

    test "returns error on invalid status" do
      assert {:error, changeset} =
               Workflows.create_workflow(Map.put(@valid_workflow_attrs, :status, "unknown"))

      assert changeset.errors[:status]
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
      workflow = create_workflow(%{status: "active"})
      assert {:ok, archived} = Workflows.archive_workflow(workflow)
      assert archived.status == "archived"
    end
  end

  # --- Run lifecycle ---

  describe "create_run/4" do
    test "creates a run with steps and settings snapshotted from the workflow" do
      workflow = create_workflow()
      assert {:ok, %WorkflowRun{} = run} = Workflows.create_run(workflow, @valid_source_event)

      assert run.workflow_id == workflow.id
      assert run.steps_snapshot == workflow.steps
      assert run.settings_snapshot == workflow.settings
      assert run.status == "pending"
      assert run.source_event == @valid_source_event
    end

    test "snapshot isolation: editing workflow after run start does not mutate the snapshot" do
      workflow = create_workflow()
      run = create_run(workflow)

      original_steps = run.steps_snapshot

      {:ok, _} = Workflows.update_workflow(workflow, %{steps: %{"new_step" => %{}}})

      reloaded_run = Workflows.get_run!(run.id)
      assert reloaded_run.steps_snapshot == original_steps
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

  describe "create_action_result/3" do
    test "inserts a :running row before step executes" do
      workflow = create_workflow()
      run = create_run(workflow)

      assert {:ok, %ActionResult{} = ar} =
               Workflows.create_action_result(run, %{
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

  describe "create_action_result/3 — started_at default" do
    test "sets started_at automatically when not provided" do
      workflow = create_workflow()
      run = create_run(workflow)

      {:ok, ar} = Workflows.create_action_result(run, %{step_name: "s", step_index: 0})
      assert ar.started_at != nil
    end

    test "preserves caller-supplied started_at" do
      workflow = create_workflow()
      run = create_run(workflow)
      explicit = ~U[2025-01-01 00:00:00Z]

      {:ok, ar} =
        Workflows.create_action_result(run, %{step_name: "s", step_index: 0, started_at: explicit})

      assert ar.started_at == explicit
    end
  end

  describe "complete_action_result/3" do
    test "sets status completed, writes results and finished_at" do
      workflow = create_workflow()
      run = create_run(workflow)
      {:ok, ar} = Workflows.create_action_result(run, %{step_name: "s", step_index: 0})

      result_map = %{"output" => "ok"}
      assert {:ok, completed} = Workflows.complete_action_result(ar, result_map)

      assert completed.status == "completed"
      assert completed.results == result_map
      assert completed.finished_at != nil
      assert completed.errors == nil
    end
  end

  describe "fail_action_result/3" do
    test "sets status failed, writes errors and finished_at" do
      workflow = create_workflow()
      run = create_run(workflow)
      {:ok, ar} = Workflows.create_action_result(run, %{step_name: "s", step_index: 0})

      error_map = %{"reason" => "timeout"}
      assert {:ok, failed} = Workflows.fail_action_result(ar, error_map)

      assert failed.status == "failed"
      assert failed.errors == error_map
      assert failed.finished_at != nil
      assert failed.results == nil
    end
  end

  describe "list_action_results/2" do
    test "returns rows ordered by step_index ascending" do
      workflow = create_workflow()
      run = create_run(workflow)

      {:ok, _} = Workflows.create_action_result(run, %{step_name: "c", step_index: 2})
      {:ok, _} = Workflows.create_action_result(run, %{step_name: "a", step_index: 0})
      {:ok, _} = Workflows.create_action_result(run, %{step_name: "b", step_index: 1})

      results = Workflows.list_action_results(run.id)
      assert Enum.map(results, & &1.step_index) == [0, 1, 2]
    end

    test "rehydration: completed rows rebuild previous_results, last running row is cursor" do
      workflow = create_workflow()
      run = create_run(workflow)

      {:ok, ar0} = Workflows.create_action_result(run, %{step_name: "fetch", step_index: 0})
      {:ok, _} = Workflows.complete_action_result(ar0, %{"data" => "fetched"})

      {:ok, ar1} = Workflows.create_action_result(run, %{step_name: "process", step_index: 1})
      {:ok, _} = Workflows.complete_action_result(ar1, %{"result" => "done"})

      # Simulate crash mid-step 2
      {:ok, _ar2} = Workflows.create_action_result(run, %{step_name: "notify", step_index: 2})

      all = Workflows.list_action_results(run.id)

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

  # --- Triggers ---

  # --- Schema accessors ---

  describe "Workflow.statuses/0" do
    test "returns the expected status list" do
      assert Workflow.statuses() == ~w(draft active archived)
    end
  end

  describe "WorkflowRun.statuses/0" do
    test "returns the expected status list" do
      assert WorkflowRun.statuses() == ~w(pending running waiting completed failed)
    end
  end

  describe "ActionResult.statuses/0" do
    test "returns the expected status list" do
      assert ActionResult.statuses() == ~w(running completed failed)
    end
  end

  describe "Trigger.types/0" do
    test "returns the expected type list" do
      assert Trigger.types() == ~w(manual webhook scheduler signal)
    end
  end

  # --- Triggers ---

  describe "create_trigger/2" do
    test "creates a trigger for a workflow" do
      workflow = create_workflow()

      assert {:ok, %Trigger{} = t} =
               Workflows.create_trigger(%{
                 workflow_id: workflow.id,
                 type: "manual",
                 config: %{},
                 enabled: true
               })

      assert t.type == "manual"
      assert t.enabled == true
    end

    test "returns error on invalid type" do
      workflow = create_workflow()

      assert {:error, changeset} =
               Workflows.create_trigger(%{workflow_id: workflow.id, type: "unknown"})

      assert changeset.errors[:type]
    end
  end

  describe "list_triggers/2" do
    test "returns triggers for a workflow" do
      workflow = create_workflow()
      {:ok, _} = Workflows.create_trigger(%{workflow_id: workflow.id, type: "manual"})
      {:ok, _} = Workflows.create_trigger(%{workflow_id: workflow.id, type: "webhook"})

      assert length(Workflows.list_triggers(workflow.id)) == 2
    end
  end

  describe "update_trigger/3" do
    test "updates trigger fields" do
      workflow = create_workflow()
      {:ok, trigger} = Workflows.create_trigger(%{workflow_id: workflow.id, type: "manual"})

      assert {:ok, updated} =
               Workflows.update_trigger(trigger, %{enabled: false, config: %{"key" => "val"}})

      assert updated.enabled == false
      assert updated.config == %{"key" => "val"}
    end

    test "returns error on invalid type" do
      workflow = create_workflow()
      {:ok, trigger} = Workflows.create_trigger(%{workflow_id: workflow.id, type: "webhook"})

      assert {:error, changeset} = Workflows.update_trigger(trigger, %{type: "invalid"})
      assert changeset.errors[:type]
    end
  end
end
