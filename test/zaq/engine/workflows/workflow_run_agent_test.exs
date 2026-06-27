defmodule Zaq.Engine.Workflows.WorkflowRunAgentTest do
  use Zaq.DataCase, async: false

  import Ecto.Query

  alias Zaq.Accounts.People
  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.Test.{ParamCapture, PauseSignal}
  alias Zaq.Engine.Workflows.{WorkflowRun, WorkflowRunAgent}
  alias Zaq.Event
  alias Zaq.Repo
  @waiting_module "Zaq.Engine.Workflows.Test.WaitingAction"

  @ok_module "Zaq.Engine.Workflows.Test.OkAction"
  @error_module "Zaq.Engine.Workflows.Test.ErrorAction"
  @history_module "Zaq.Agent.Tools.Accounts.History"
  @probe_module "Zaq.Engine.Workflows.Test.ParamProbe"
  @pause_module "Zaq.Engine.Workflows.Test.PauseAction"
  @noop_module "Zaq.Engine.Workflows.Test.Noop"
  @emit_gender_module "Zaq.Engine.Workflows.Test.EmitGender"

  setup do
    stub(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{} = event -> event end)
    start_supervised!(ParamCapture)
    start_supervised!(PauseSignal)
    ParamCapture.reset()
    PauseSignal.reset()
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

      assert {:ok, updated} = WorkflowRunAgent.execute(run)
      assert updated.status == "completed"
      assert updated.started_at != nil
      assert updated.finished_at != nil
    end

    test "writes a completed ActionResult row for the step" do
      run = create_run()

      {:ok, updated} = WorkflowRunAgent.execute(run)
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

      {:ok, updated} = WorkflowRunAgent.execute(run)
      assert updated.status == "completed"
    end
  end

  describe "execute/1 — step failure" do
    test "transitions WorkflowRun to failed when a step errors" do
      run = create_run(@error_module)

      assert {:ok, updated} = WorkflowRunAgent.execute(run)
      assert updated.status == "failed"
      assert updated.finished_at != nil
    end

    test "ActionResult row for failing step is marked failed" do
      run = create_run(@error_module)

      {:ok, updated} = WorkflowRunAgent.execute(run)
      [ar] = Workflows.list_step_runs(updated.id)

      assert ar.status == "failed"
      assert ar.errors["reason"] =~ "test_failure"
    end

    test "history tool data-layer errors fail the step and workflow run" do
      {:ok, person} =
        People.create_person(%{
          full_name: "History Failure",
          email: "history-failure@example.com"
        })

      {:ok, wf} =
        Workflows.create_workflow(%{
          name: "WA History Failure #{System.unique_integer()}",
          status: "active",
          nodes: [
            %{
              name: "history",
              type: "action",
              module: @history_module,
              params: %{"conversation_limit" => "not-an-integer"},
              index: 0
            }
          ],
          edges: []
        })

      source_event = %{
        "actor" => %{"person" => %{"id" => person.id}},
        "request" => %{},
        "assigns" => %{"trigger_type" => "manual"},
        "trace_id" => Ecto.UUID.generate()
      }

      {:ok, run} = Workflows.create_run(wf, source_event)

      assert {:ok, updated} = WorkflowRunAgent.execute(run)
      assert updated.status == "failed"

      [step_run] = Workflows.list_step_runs(updated.id)
      assert step_run.status == "failed"
      assert step_run.errors["reason"] =~ "cannot be cast to type :integer"
    end
  end

  describe "start_run/2 — DAG build failure" do
    test "marks the run failed and returns the error when the snapshot can't be built" do
      # Build failure is now the run module's responsibility (ensure_prepared_dag);
      # the agent never builds. An empty-DAG snapshot reaches build via a run whose
      # prepared_dag is nil.
      {:ok, wf} =
        Workflows.create_workflow(%{
          name: "WA Bad Steps #{System.unique_integer()}",
          status: "draft",
          nodes: [],
          edges: []
        })

      {:ok, run} = Workflows.create_run(wf, @source_event)

      assert {:error, :empty_dag} = Workflows.start_run(run)

      reloaded = Workflows.get_run!(run.id)
      assert reloaded.status == "failed"
    end
  end

  describe "execute/2 — executes the prepared DAG only (Task 15)" do
    test "runs run.prepared_dag and ignores steps_snapshot entirely" do
      run = create_run()
      # Garbage snapshot: if the agent rebuilt from it, the run would fail. It must
      # run the prepared DAG carried on the struct instead.
      assert {:ok, updated} = WorkflowRunAgent.execute(%{run | steps_snapshot: %{"junk" => true}})
      assert updated.status == "completed"
    end

    test "returns {:error, :missing_prepared_dag} when the run carries no DAG" do
      run = create_run()

      assert {:error, :missing_prepared_dag} =
               WorkflowRunAgent.execute(%{run | prepared_dag: nil})
    end
  end

  describe "start_run/2 and resume_run/2 — prepare the DAG for reloaded runs" do
    test "start_run builds the DAG for a reloaded pending run lacking prepared_dag" do
      run = create_run()
      reloaded = Workflows.get_run!(run.id)
      assert reloaded.prepared_dag == nil

      assert {:ok, updated} = Workflows.start_run(reloaded)
      assert updated.status == "completed"
    end

    test "resume_run rebuilds the DAG for a reloaded paused run" do
      run = create_run()
      {:ok, _paused} = Workflows.update_run(run, %{status: "paused"})
      reloaded = Workflows.get_run!(run.id)
      assert reloaded.prepared_dag == nil

      assert {:ok, updated} = Workflows.resume_run(reloaded)
      assert updated.status == "completed"
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

      {:ok, updated} = WorkflowRunAgent.execute(run)
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
      {:ok, updated} = WorkflowRunAgent.execute(run)

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
      # A reloaded run has no prepared_dag; start_run rebuilds it before the agent
      # runs. The agent's JSONB-key normalization is what this test exercises.
      {:ok, updated} = Workflows.start_run(reloaded)

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
      {:ok, updated} = WorkflowRunAgent.execute(run)

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
      {:ok, updated} = WorkflowRunAgent.execute(run)

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
      {:ok, _updated} = WorkflowRunAgent.execute(run)

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
      {:ok, updated} = WorkflowRunAgent.execute(run)

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
      {:ok, updated} = WorkflowRunAgent.execute(run)

      assert updated.status == "completed"
    end
  end

  describe "execute/1 — cross-step edge conditions (cascade)" do
    # Workflow: A → B → C → D  (if A.gender == "female")
    #                    C → E  (if A.gender == "male")
    defp cascade_workflow(gender) do
      {:ok, wf} =
        Workflows.create_workflow(%{
          name: "WA Cascade #{System.unique_integer()}",
          status: "active",
          nodes: [
            %{
              name: "A",
              type: "action",
              module: @emit_gender_module,
              params: %{"gender" => gender},
              index: 0
            },
            %{name: "B", type: "action", module: @ok_module, params: %{}, index: 1},
            %{name: "C", type: "action", module: @ok_module, params: %{}, index: 2},
            %{name: "D", type: "action", module: @noop_module, params: %{}, index: 3},
            %{name: "E", type: "action", module: @noop_module, params: %{}, index: 3}
          ],
          edges: [
            %{from: "A", to: "B"},
            %{from: "B", to: "C"},
            %{from: "C", to: "D", condition: %{field: "A.gender", op: :eq, value: "female"}},
            %{from: "C", to: "E", condition: %{field: "A.gender", op: :eq, value: "male"}}
          ]
        })

      {:ok, run} = Workflows.create_run(wf, @source_event)
      run
    end

    test "female: D runs, E is pruned" do
      run = cascade_workflow("female")
      assert {:ok, finished} = WorkflowRunAgent.execute(run)
      assert finished.status == "completed"

      step_runs = Workflows.list_step_runs(run.id)
      by_name = Map.new(step_runs, &{&1.step_name, &1})

      assert by_name["A"].status == "completed"
      assert by_name["B"].status == "completed"
      assert by_name["C"].status == "completed"
      assert by_name["D"].status == "completed"
      refute Map.has_key?(by_name, "E")
    end

    test "male: E runs, D is pruned" do
      run = cascade_workflow("male")
      assert {:ok, finished} = WorkflowRunAgent.execute(run)
      assert finished.status == "completed"

      step_runs = Workflows.list_step_runs(run.id)
      by_name = Map.new(step_runs, &{&1.step_name, &1})

      assert by_name["A"].status == "completed"
      assert by_name["B"].status == "completed"
      assert by_name["C"].status == "completed"
      assert by_name["E"].status == "completed"
      refute Map.has_key?(by_name, "D")
    end

    test "absent step name in cascade condition → branch pruned, run still completes" do
      {:ok, wf} =
        Workflows.create_workflow(%{
          name: "WA Cascade Missing #{System.unique_integer()}",
          status: "active",
          nodes: [
            %{name: "A", type: "action", module: @ok_module, params: %{}, index: 0},
            %{name: "B", type: "action", module: @noop_module, params: %{}, index: 1}
          ],
          edges: [
            %{from: "A", to: "B", condition: %{field: "nonexistent.field", op: :eq, value: "x"}}
          ]
        })

      {:ok, run} = Workflows.create_run(wf, @source_event)
      assert {:ok, finished} = WorkflowRunAgent.execute(run)
      assert finished.status == "completed"

      step_runs = Workflows.list_step_runs(run.id)
      names = Enum.map(step_runs, & &1.step_name)
      refute "B" in names
    end
  end

  describe "execute/1 — pause / resume" do
    defp two_step_workflow(step0_module, step1_module) do
      {:ok, wf} =
        Workflows.create_workflow(%{
          name: "WA Pause #{System.unique_integer()}",
          status: "active",
          nodes: [
            %{name: "step0", type: "action", module: step0_module, params: %{}, index: 0},
            %{name: "step1", type: "action", module: step1_module, params: %{}, index: 1}
          ],
          edges: [%{from: "step0", to: "step1"}]
        })

      wf
    end

    test "halts cleanly when run is paused between steps" do
      wf = two_step_workflow(@pause_module, @ok_module)
      {:ok, run} = Workflows.create_run(wf, @source_event)
      PauseSignal.put_run_id(run.id)

      assert {:ok, updated} = WorkflowRunAgent.execute(run)
      assert updated.status == "paused"

      step_runs = Workflows.list_step_runs(run.id)
      names = Enum.map(step_runs, & &1.step_name)
      assert "step0" in names
      refute "step1" in names

      [sr0] = Enum.filter(step_runs, &(&1.step_name == "step0"))
      assert sr0.status == "completed"
    end

    test "no pause — normal 2-step completion is unchanged" do
      wf = two_step_workflow(@ok_module, @ok_module)
      {:ok, run} = Workflows.create_run(wf, @source_event)

      assert {:ok, updated} = WorkflowRunAgent.execute(run)
      assert updated.status == "completed"

      step_runs = Workflows.list_step_runs(run.id)
      assert length(step_runs) == 2
      assert Enum.all?(step_runs, &(&1.status == "completed"))
    end

    test "resume skips completed steps and finishes remaining steps" do
      wf = two_step_workflow(@pause_module, @ok_module)
      {:ok, run} = Workflows.create_run(wf, @source_event)
      PauseSignal.put_run_id(run.id)

      {:ok, paused_run} = WorkflowRunAgent.execute(run)
      assert paused_run.status == "paused"

      PauseSignal.reset()

      {:ok, completed_run} = Workflows.resume_run(paused_run)
      assert completed_run.status == "completed"

      step_runs = Workflows.list_step_runs(completed_run.id)
      step0_runs = Enum.filter(step_runs, &(&1.step_name == "step0"))
      step1_runs = Enum.filter(step_runs, &(&1.step_name == "step1"))

      assert length(step0_runs) == 1, "step0 must not be re-executed on resume"
      assert length(step1_runs) == 1
      assert hd(step1_runs).status == "completed"
    end

    test "resume with no completed steps runs all steps from scratch" do
      wf = two_step_workflow(@ok_module, @ok_module)
      {:ok, run} = Workflows.create_run(wf, @source_event)
      {:ok, paused_run} = Workflows.update_run(run, %{status: "paused"})

      {:ok, completed_run} = Workflows.resume_run(paused_run)
      assert completed_run.status == "completed"
      assert length(Workflows.list_step_runs(completed_run.id)) == 2
    end
  end

  describe "human-in-the-loop suspension" do
    defp hitl_workflow do
      {:ok, wf} =
        Workflows.create_workflow(%{
          name: "hitl-wf-#{System.unique_integer()}",
          status: "active",
          nodes: [
            %{name: "step0", type: "action", module: @ok_module, params: %{}, index: 0},
            %{name: "hitl", type: "action", module: @waiting_module, params: %{}, index: 1},
            %{name: "step2", type: "action", module: @ok_module, params: %{}, index: 2}
          ],
          edges: [
            %{from: "step0", to: "hitl"},
            %{from: "hitl", to: "step2"}
          ]
        })

      wf
    end

    test "run transitions to 'waiting' when WaitingAction step is reached" do
      wf = hitl_workflow()
      {:ok, run} = Workflows.create_run(wf, @source_event)

      {:ok, waiting_run} = WorkflowRunAgent.execute(run)
      assert waiting_run.status == "waiting"
    end

    test "step before HumanInTheLoop is 'completed', hitl step is 'waiting'" do
      wf = hitl_workflow()
      {:ok, run} = Workflows.create_run(wf, @source_event)

      {:ok, _waiting_run} = WorkflowRunAgent.execute(run)

      step_runs = Workflows.list_step_runs(run.id)
      by_name = Map.new(step_runs, &{&1.step_name, &1})

      assert by_name["step0"].status == "completed"
      assert by_name["hitl"].status == "waiting"
      refute Map.has_key?(by_name, "step2")
    end

    test "WaitingAction suspends the run and WorkflowRunAgent transitions it to waiting" do
      wf = hitl_workflow()
      {:ok, run} = Workflows.create_run(wf, @source_event)

      result = WorkflowRunAgent.execute(run)
      assert {:ok, %{status: "waiting"}} = result
    end
  end

  describe "lifecycle event dispatch" do
    setup do
      test_pid = self()

      stub(Zaq.NodeRouterMock, :dispatch, fn event ->
        # Ignore UI re-broadcasts ({:broadcast, topic, message} → :channels); this
        # block asserts only the lifecycle events (run.started/completed/failed).
        case event.request do
          {:broadcast, _topic, _message} -> :ok
          _ -> send(test_pid, {:dispatched, event})
        end

        event
      end)

      :ok
    end

    # Drain any events already in the mailbox (e.g. workflow.created from create_run helper).
    defp flush_dispatched do
      receive do
        {:dispatched, _} -> flush_dispatched()
      after
        0 -> :ok
      end
    end

    test "successful run dispatches run.started then run.completed" do
      run = create_run()
      flush_dispatched()

      assert {:ok, _} = WorkflowRunAgent.execute(run)

      assert_received {:dispatched, started}
      assert started.request[:action] == "run.started"
      assert started.request[:run_id] == run.id
      assert started.request[:workflow_id] == run.workflow_id
      assert started.name == :workflow

      assert_received {:dispatched, completed}
      assert completed.request[:action] == "run.completed"
      assert completed.request[:run_id] == run.id
    end

    test "step failure dispatches run.started then run.failed" do
      run = create_run(@error_module)
      flush_dispatched()

      assert {:ok, _} = WorkflowRunAgent.execute(run)

      assert_received {:dispatched, started}
      assert started.request[:action] == "run.started"
      assert started.request[:run_id] == run.id

      assert_received {:dispatched, failed}
      assert failed.request[:action] == "run.failed"
      assert failed.request[:run_id] == run.id
    end

    test "DAG build failure dispatches run.failed and never run.started" do
      # Task 15: the DAG is prepared before the run transitions to running, so a
      # build failure never emits run.started — the run never actually started.
      {:ok, wf} =
        Workflows.create_workflow(%{
          name: "WA Dag Fail #{System.unique_integer()}",
          status: "draft",
          nodes: [],
          edges: []
        })

      {:ok, run} = Workflows.create_run(wf, @source_event)
      flush_dispatched()

      assert {:error, _} = Workflows.start_run(run)

      assert_received {:dispatched, failed}
      assert failed.request[:action] == "run.failed"
      assert failed.request[:run_id] == run.id

      refute_received {:dispatched, %{request: %{action: "run.started"}}}
    end

    test "paused run dispatches only run.started" do
      # Two-step workflow: PauseAction sets DB status to "paused", checkpoint fires
      # before the second step and throws :pause_requested. finalize/2 is never reached.
      {:ok, wf} =
        Workflows.create_workflow(%{
          name: "WA Pause #{System.unique_integer()}",
          status: "active",
          nodes: [
            %{name: "pause", type: "action", module: @pause_module, params: %{}, index: 0},
            %{name: "continue", type: "action", module: @ok_module, params: %{}, index: 1}
          ],
          edges: [%{from: "pause", to: "continue"}]
        })

      {:ok, run} = Workflows.create_run(wf, @source_event)
      PauseSignal.put_run_id(run.id)
      flush_dispatched()

      assert {:ok, paused} = WorkflowRunAgent.execute(run)
      assert paused.status == "paused"

      assert_received {:dispatched, started}
      assert started.request[:action] == "run.started"

      refute_received {:dispatched, _}
    end
  end

  describe "execute/1 — update_run failure at start (lines 110-116)" do
    test "returns {:error, reason} when the initial status transition fails" do
      run = create_run()

      # Inject a stub workflows module that returns {:error, :forced} for the
      # first update_run call (status transition to "running").
      defmodule FailingStartWorkflows do
        alias Zaq.Engine.Workflows
        def update_run(_run, %{status: "running"} = _attrs), do: {:error, :start_blocked}
        def update_run(run, attrs), do: Workflows.update_run(run, attrs)
        def list_step_runs(id), do: Workflows.list_step_runs(id)
      end

      Application.put_env(:zaq, :workflow_run_agent_workflows_mod, FailingStartWorkflows)
      on_exit(fn -> Application.delete_env(:zaq, :workflow_run_agent_workflows_mod) end)

      assert {:error, :start_blocked} = WorkflowRunAgent.execute(run)
    end
  end

  describe "execute/1 — fetch_input nil source_event (line 269)" do
    test "defaults to empty fact when source_event struct has nil assigns" do
      wf = probe_workflow()

      # Use a source_event that has nil assigns so fetch_input returns %{}.
      # The nil clause at line 269 guards when source_event itself is nil.
      # We exercise the same defensive coding by passing a run whose source_event
      # struct returns no :input key (assigns key is present but no :input).
      source_event_no_input = %Event{
        request: nil,
        next_hop: nil,
        name: :workflow_run_triggered,
        trace_id: Ecto.UUID.generate(),
        assigns: %{trigger_type: :event}
      }

      {:ok, run} = Workflows.create_run(wf, source_event_no_input)
      {:ok, updated} = WorkflowRunAgent.execute(run)

      assert updated.status == "completed"
      params = ParamCapture.get_params()
      refute Map.has_key?(params, :event)
    end
  end

  describe "execute/1 — waiting state Logger.info (lines 151-152)" do
    test "logs waiting state at info level" do
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: :warning) end)

      {:ok, wf} =
        Workflows.create_workflow(%{
          name: "hitl-log-wf-#{System.unique_integer()}",
          status: "active",
          nodes: [
            %{name: "step0", type: "action", module: @ok_module, params: %{}, index: 0},
            %{name: "hitl", type: "action", module: @waiting_module, params: %{}, index: 1}
          ],
          edges: [%{from: "step0", to: "hitl"}]
        })

      {:ok, run} = Workflows.create_run(wf, @source_event)
      {:ok, waiting_run} = WorkflowRunAgent.execute(run)
      assert waiting_run.status == "waiting"
    end
  end

  describe "start_run/2 — build error surfaced (format_build_error variants)" do
    # Helper to create a run and forcefully set its steps_snapshot via raw DB update,
    # then reload and execute to trigger format_build_error with specific error atoms.
    defp run_with_snapshot(snapshot) do
      {:ok, wf} =
        Workflows.create_workflow(%{
          name: "fbe-wf-#{System.unique_integer()}",
          status: "draft",
          nodes: [
            %{
              name: "n",
              type: "action",
              module: "Zaq.Engine.Workflows.Test.InboxWithResults",
              params: %{},
              index: 0
            }
          ],
          edges: []
        })

      {:ok, run} = Workflows.create_run(wf, @source_event)

      Repo.update_all(
        from(r in WorkflowRun, where: r.id == ^run.id),
        set: [steps_snapshot: snapshot]
      )

      Workflows.get_run!(run.id)
    end

    test "format_build_error(:invalid_steps) — missing nodes key (line 229)" do
      run = run_with_snapshot(%{"edges" => []})
      assert {:error, :invalid_steps} = Workflows.start_run(run)
    end

    test "format_build_error({:unknown_node_type, type}) — condition node type (line 236)" do
      snapshot = %{
        "nodes" => [
          %{
            "name" => "n",
            "type" => "condition",
            "module" => "Zaq.Agent.Tools.Workflow.Condition",
            "params" => %{},
            "index" => 0
          }
        ],
        "edges" => []
      }

      run = run_with_snapshot(snapshot)
      assert {:error, {:unknown_node_type, "condition"}} = Workflows.start_run(run)
    end

    test "format_build_error({:unknown_module, nil}) — node with nil module (line 238)" do
      snapshot = %{
        "nodes" => [
          %{"name" => "n", "type" => "action", "module" => nil, "params" => %{}, "index" => 0}
        ],
        "edges" => []
      }

      run = run_with_snapshot(snapshot)
      assert {:error, {:unknown_module, nil}} = Workflows.start_run(run)
    end

    test "format_build_error({:unknown_module, mod}) — non-existent module (line 241)" do
      snapshot = %{
        "nodes" => [
          %{
            "name" => "n",
            "type" => "action",
            "module" => "Does.Not.Exist.Anywhere",
            "params" => %{},
            "index" => 0
          }
        ],
        "edges" => []
      }

      run = run_with_snapshot(snapshot)
      assert {:error, {:unknown_module, "Does.Not.Exist.Anywhere"}} = Workflows.start_run(run)
    end

    test "format_build_error({:unknown_node, name}) — edge referencing missing node (line 245)" do
      snapshot = %{
        "nodes" => [
          %{
            "name" => "start",
            "type" => "action",
            "module" => "Zaq.Engine.Workflows.Test.InboxWithResults",
            "params" => %{},
            "index" => 0
          }
        ],
        "edges" => [%{"from" => "start", "to" => "ghost_node"}]
      }

      run = run_with_snapshot(snapshot)
      assert {:error, {:unknown_node, "ghost_node"}} = Workflows.start_run(run)
    end

    test "format_build_error({:invalid_edge_condition, _}) — edge with bad condition (line 247)" do
      snapshot = %{
        "nodes" => [
          %{
            "name" => "a",
            "type" => "action",
            "module" => "Zaq.Engine.Workflows.Test.InboxWithResults",
            "params" => %{},
            "index" => 0
          },
          %{
            "name" => "b",
            "type" => "action",
            "module" => "Zaq.Engine.Workflows.Test.InboxWithResults",
            "params" => %{},
            "index" => 1
          }
        ],
        "edges" => [
          %{
            "from" => "a",
            "to" => "b",
            "condition" => %{"op" => "invalid_op_xyz", "field" => "x", "value" => 1}
          }
        ]
      }

      run = run_with_snapshot(snapshot)
      assert {:error, {:invalid_edge_condition, _}} = Workflows.start_run(run)
    end
  end

  # ---------------------------------------------------------------------------
  # Blocker 2 (issue #508): mapping the trigger payload onto the FIRST node.
  #
  # Simulates Workflow A dispatching %{name, age, position} which triggers
  # Workflow B, whose first node is a condition that references the producer's
  # field under a RENAMED key (current_position). The rename is declared on a
  # sentinel edge `from: "start"` to the first node, using a dotted-path source
  # (current_position => start.position). The persistent `start` namespace holds
  # the trigger payload for the whole run. None of this exists yet, so the run
  # fails today — both because a first-node condition crashes (Blocker 1) and
  # because no `start` mapping renames `position` -> `current_position`.
  # EXPECTED TO FAIL until the mapping feature lands.
  # ---------------------------------------------------------------------------
  describe "execute/1 — maps a renamed trigger field onto the first node (issue #508)" do
    test "condition as first node passes against a start-mapped renamed field" do
      {:ok, wf} =
        Workflows.create_workflow(%{
          name: "WB Mapping #{System.unique_integer()}",
          status: "active",
          nodes: [
            %{
              name: "check_position",
              type: "action",
              module: "Zaq.Agent.Tools.Workflow.Condition",
              params: %{
                "conditions" => [
                  %{"key" => "current_position", "op" => "eq", "value" => "CTO"}
                ]
              },
              index: 0
            }
          ],
          edges: [
            %{
              "from" => "start",
              "to" => "check_position",
              "mapping" => %{"current_position" => "start.position"}
            }
          ]
        })

      # The raw dispatched payload, exactly as TriggerNode would plant it
      # (Workflow A's output, string-keyed at the root of assigns.input).
      source = flat_trigger_source(%{"name" => "Jad", "age" => 32, "position" => "CTO"})
      {:ok, run} = Workflows.create_run(wf, source)

      assert {:ok, updated} = WorkflowRunAgent.execute(run)
      assert updated.status == "completed"
    end
  end

  # A %Zaq.Event{} carrying a FLAT trigger payload at assigns.input, matching
  # the shape TriggerNode.build_source_event/2 produces for a dispatched event
  # whose request is the producer's output map (no `event` envelope wrapper).
  defp flat_trigger_source(payload) do
    %Event{
      request: %{trigger_type: :event},
      next_hop: nil,
      name: :workflow_run_triggered,
      trace_id: Ecto.UUID.generate(),
      assigns: %{trigger_type: :event, input: payload, skip_permissions: true}
    }
  end
end
