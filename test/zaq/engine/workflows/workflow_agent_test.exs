defmodule Zaq.Engine.Workflows.WorkflowAgentTest do
  use Zaq.DataCase, async: false

  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.Test.ParamCapture
  alias Zaq.Engine.Workflows.WorkflowAgent
  alias Zaq.Event

  @ok_module "Zaq.Engine.Workflows.Test.OkAction"
  @error_module "Zaq.Engine.Workflows.Test.ErrorAction"
  @probe_module "Zaq.Engine.Workflows.Test.ParamProbe"

  setup do
    start_supervised!(ParamCapture)
    ParamCapture.reset()
    :ok
  end

  @source_event %{
    "request" => nil,
    "assigns" => %{"trigger_type" => "manual"},
    "trace_id" => Ecto.UUID.generate()
  }

  defp create_run(module \\ @ok_module) do
    {:ok, wf} =
      Workflows.create_workflow(%{
        name: "WA Test #{System.unique_integer()}",
        status: "active",
        nodes: [%{name: "step", type: "action", module: module, params: %{}, index: 0}],
        edges: []
      })

    {:ok, run} = Workflows.create_run(wf, @source_event)
    run
  end

  defp probe_workflow do
    {:ok, wf} =
      Workflows.create_workflow(%{
        name: "WA Probe #{System.unique_integer()}",
        status: "active",
        nodes: [%{name: "probe", type: "action", module: @probe_module, params: %{}, index: 0}],
        edges: []
      })

    wf
  end

  # Builds an atom-keyed %Zaq.Event{} in the Input Contract shape produced by
  # TriggerNode.build_source_event/2. Passed verbatim to create_run, this
  # simulates the synchronous trigger path (struct never reloaded from DB).
  defp event_source(payload, extra_assigns \\ %{}) do
    trace_id = Ecto.UUID.generate()

    %Event{
      request: %{trigger_type: :event},
      next_hop: nil,
      name: :workflow_run_triggered,
      trace_id: trace_id,
      assigns:
        Map.merge(extra_assigns, %{
          trigger_type: :event,
          input: %{
            event: %{
              name: :email_received,
              trace_id: trace_id,
              payload: payload,
              assigns: %{}
            }
          }
        })
    }
  end

  describe "execute/1 — happy path" do
    test "transitions WorkflowRun to completed" do
      run = create_run()

      assert {:ok, updated} = WorkflowAgent.execute(run)
      assert updated.status == "completed"
      assert updated.started_at != nil
      assert updated.finished_at != nil
    end

    test "writes a completed ActionResult row for the step" do
      run = create_run()

      {:ok, updated} = WorkflowAgent.execute(run)
      results = Workflows.list_step_runs(updated.id)

      assert length(results) == 1
      [ar] = results
      assert ar.step_name == "step"
      assert ar.status == "completed"
      assert ar.finished_at != nil
    end

    test "run starts at pending and transitions through running to completed" do
      run = create_run()
      assert run.status == "pending"

      {:ok, updated} = WorkflowAgent.execute(run)
      assert updated.status == "completed"
    end
  end

  describe "execute/1 — step failure" do
    test "transitions WorkflowRun to failed when a step errors" do
      run = create_run(@error_module)

      assert {:ok, updated} = WorkflowAgent.execute(run)
      assert updated.status == "failed"
      assert updated.finished_at != nil
    end

    test "ActionResult row for failing step is marked failed" do
      run = create_run(@error_module)

      {:ok, updated} = WorkflowAgent.execute(run)
      [ar] = Workflows.list_step_runs(updated.id)

      assert ar.status == "failed"
      assert ar.errors["reason"] =~ "test_failure"
    end
  end

  describe "execute/1 — DagBuilder failure" do
    test "transitions WorkflowRun to failed when steps snapshot is invalid" do
      {:ok, wf} =
        Workflows.create_workflow(%{
          name: "WA Bad Steps #{System.unique_integer()}",
          status: "draft",
          nodes: [],
          edges: []
        })

      {:ok, run} = Workflows.create_run(wf, @source_event)

      assert {:error, _} = WorkflowAgent.execute(run)

      reloaded = Workflows.get_run!(run.id)
      assert reloaded.status == "failed"
    end
  end

  describe "execute/1 — multi-step workflow" do
    test "writes one ActionResult per action step" do
      {:ok, wf} =
        Workflows.create_workflow(%{
          name: "WA Multi #{System.unique_integer()}",
          status: "active",
          nodes: [
            %{name: "first", type: "action", module: @ok_module, params: %{}, index: 0},
            %{name: "second", type: "action", module: @ok_module, params: %{}, index: 1}
          ],
          edges: [%{from: "first", to: "second"}]
        })

      {:ok, run} = Workflows.create_run(wf, @source_event)

      {:ok, updated} = WorkflowAgent.execute(run)
      assert updated.status == "completed"

      results = Workflows.list_step_runs(updated.id)
      assert length(results) == 2
      assert Enum.all?(results, &(&1.status == "completed"))
    end
  end

  describe "execute/1 — Step 2: payload reaches the first action as params.event.payload" do
    test "synchronous path (atom-keyed source_event): payload reaches the action" do
      payload = %{"user_id" => 123, "email" => "test@example.com"}
      wf = probe_workflow()

      {:ok, run} = Workflows.create_run(wf, event_source(payload))
      {:ok, updated} = WorkflowAgent.execute(run)

      assert updated.status == "completed"
      params = ParamCapture.get_params()
      assert params[:event][:payload] == payload
    end

    test "DB-reloaded path (JSONB string-keyed): payload still reaches action as atom keys" do
      payload = %{"email" => "user@example.com"}
      wf = probe_workflow()

      {:ok, run} = Workflows.create_run(wf, event_source(payload))
      # Reloading from the DB forces the JSONB round-trip → deeply string-keyed
      # assigns. This is the critical regression path from the plan.
      reloaded = Workflows.get_run!(run.id)
      {:ok, updated} = WorkflowAgent.execute(reloaded)

      assert updated.status == "completed"
      params = ParamCapture.get_params()
      # Normalization (option a) guarantees atom structural keys on BOTH paths.
      assert params[:event][:payload] == payload
      assert Map.has_key?(params, :event)
      refute Map.has_key?(params, "event")
    end

    test "defaults to empty fact when assigns lacks input key (legacy fallback)" do
      wf = probe_workflow()

      # @source_event has trigger_type but no :input key
      {:ok, run} = Workflows.create_run(wf, @source_event)
      {:ok, updated} = WorkflowAgent.execute(run)

      assert updated.status == "completed"
      params = ParamCapture.get_params()
      refute Map.has_key?(params, :event)
      refute Map.has_key?(params, "event")
    end

    test "removes assigns leak: sibling assigns keys do not reach the action" do
      payload = %{"clean" => "data"}
      wf = probe_workflow()

      source_event = event_source(payload, %{internal_flag: "should_not_leak"})
      {:ok, run} = Workflows.create_run(wf, source_event)
      {:ok, updated} = WorkflowAgent.execute(run)

      assert updated.status == "completed"
      params = ParamCapture.get_params()
      assert params[:event][:payload] == payload
      # The full assigns map (trigger_type, internal_flag) must NOT leak through.
      refute Map.has_key?(params, :internal_flag)
      refute Map.has_key?(params, "internal_flag")
      refute Map.has_key?(params, :trigger_type)
    end

    test "preserves event metadata (name, trace_id, assigns) under the :event key" do
      payload = %{"k" => "v"}
      wf = probe_workflow()

      {:ok, run} = Workflows.create_run(wf, event_source(payload))
      {:ok, _updated} = WorkflowAgent.execute(run)

      params = ParamCapture.get_params()
      assert params[:event][:name] == :email_received
      assert is_binary(params[:event][:trace_id])
      assert params[:event][:assigns] == %{}
    end
  end

  describe "execute/1 — log and defensive paths" do
    test "evaluates run-started/run-completed log metadata when info logging is enabled" do
      # Test env sets Logger level to :warning, which suppresses Logger.info
      # argument evaluation. Enabling :info exercises the run-started and
      # run-completed metadata builders (including fetch_trigger_type/1).
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: :warning) end)

      payload = %{"k" => "v"}
      wf = probe_workflow()

      {:ok, run} = Workflows.create_run(wf, event_source(payload))
      {:ok, updated} = WorkflowAgent.execute(run)

      assert updated.status == "completed"
    end

    test "passes a non-map resolved input through unchanged (normalize_input fallback)" do
      wf = probe_workflow()

      source_event = %Event{
        request: nil,
        next_hop: nil,
        name: :workflow_run_triggered,
        trace_id: Ecto.UUID.generate(),
        assigns: %{trigger_type: :event, input: "raw-non-map-input"}
      }

      {:ok, run} = Workflows.create_run(wf, source_event)
      {:ok, updated} = WorkflowAgent.execute(run)

      assert updated.status == "completed"
    end
  end
end
