defmodule Zaq.Engine.Workflows.ActionWrapperTest do
  use Zaq.DataCase, async: true

  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.ActionWrapper
  alias Zaq.Engine.Workflows.Conditions.ConditionNotMet

  import ExUnit.CaptureLog

  alias Zaq.Engine.Workflows.Test.{
    ContextCaptureAction,
    ContextProbe,
    DraftReplyStub,
    ErrorAction,
    OkAction,
    OkWithLogsAction,
    WaitingAction
  }

  alias Zaq.Test.Stubs

  setup do
    Stubs.stub_node_router()
    :ok
  end

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
    create_run_with_source_event(@valid_source_event)
  end

  defp create_run_with_source_event(source_event) do
    {:ok, wf} = Workflows.create_workflow(@valid_workflow_attrs)
    {:ok, run} = Workflows.create_run(wf, source_event)
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

      assert [%{"event" => "step_completed", "duration_ms" => dur}] = ar.logs
      assert dur >= 0
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

      # step_completed entry prepended before action-emitted logs
      assert [%{"event" => "step_completed"} | action_logs] = ar.logs
      assert length(action_logs) == 1
      assert hd(action_logs)["message"] == "step log"
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

      assert [%{"event" => "step_failed", "reason" => reason, "duration_ms" => dur}] = ar.logs
      assert dur >= 0
      assert reason =~ "test_failure"
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

  describe "run/2 — waiting_for_human handling" do
    test "marks StepRun as 'waiting' and returns {:error, :waiting_for_human}" do
      run = create_run()

      assert {:error, :waiting_for_human} =
               ActionWrapper.run(wp(run, WaitingAction, "hitl_step", 0), %{})

      [ar] = Workflows.list_step_runs(run.id)
      assert ar.status == "waiting"
      assert ar.step_name == "hitl_step"
    end

    test "does not mark StepRun as failed when step returns waiting_for_human" do
      run = create_run()
      ActionWrapper.run(wp(run, WaitingAction, "review", 0), %{})

      [ar] = Workflows.list_step_runs(run.id)
      refute ar.status == "failed"
      assert ar.status == "waiting"
    end
  end

  describe "run/2 — retry idempotency (skip already-terminal step)" do
    test "returns error tuple without re-executing when step is already failed" do
      run = create_run()

      {:ok, sr} =
        Workflows.create_step_run(run, %{step_name: "draft", step_index: 1, status: "running"})

      {:ok, _} = Workflows.fail_step_run(sr, %{reason: "first attempt"})

      assert {:error, _} = ActionWrapper.run(wp(run, OkAction, "draft", 1), %{})

      rows = Workflows.list_step_runs(run.id)
      assert length(rows) == 1, "must not create a duplicate StepRun on retry"
    end

    test "does not call the wrapped module when step is already failed" do
      run = create_run()

      {:ok, sr} =
        Workflows.create_step_run(run, %{step_name: "draft", step_index: 1, status: "running"})

      {:ok, _} = Workflows.fail_step_run(sr, %{reason: "already done"})

      call_count = :counters.new(1, [])

      defmodule NeverCalledAction do
        @moduledoc false
        use Jido.Action, name: "never_called_action_aw", schema: []

        def run(_params, _context) do
          :counters.add(:persistent_term.get(:never_called_aw_counter), 1, 1)
          {:ok, %{called: true}}
        end
      end

      :persistent_term.put(:never_called_aw_counter, call_count)

      ActionWrapper.run(wp(run, NeverCalledAction, "draft", 1), %{})
      assert :counters.get(call_count, 1) == 0, "wrapped module must not be called on retry"
    end

    test "returns {:error, :condition_not_met} without re-executing when step is already skipped" do
      run = create_run()

      {:ok, sr} =
        Workflows.create_step_run(run, %{step_name: "edge", step_index: 0, status: "running"})

      {:ok, _} =
        Workflows.skip_step_run(sr, %{field: "count", op: "gt", actual: 0, expected: 5})

      assert {:error, :condition_not_met} = ActionWrapper.run(wp(run, OkAction, "edge", 0), %{})

      rows = Workflows.list_step_runs(run.id)
      assert length(rows) == 1, "must not create a duplicate StepRun"
    end

    test "returns {:error, :waiting_for_human} without re-executing when step is already waiting" do
      run = create_run()

      {:ok, sr} =
        Workflows.create_step_run(run, %{step_name: "hitl", step_index: 1, status: "running"})

      {:ok, _} = Workflows.wait_step_run(sr)

      assert {:error, :waiting_for_human} = ActionWrapper.run(wp(run, OkAction, "hitl", 1), %{})

      rows = Workflows.list_step_runs(run.id)
      assert length(rows) == 1, "must not create a duplicate StepRun"
    end
  end

  describe "run/2 — per-action timeout" do
    @hardcoded_email %{
      "message_id" => "test-001",
      "from" => %{"name" => "Alice", "address" => "alice@example.com"},
      "subject" => "Question about your service",
      "body_text" => "Hello, I have a question about your pricing."
    }

    defp timed_params(run, delay_ms, timeout_ms) do
      wp(run, DraftReplyStub, "draft", 0)
      |> Map.put(:emails, [@hardcoded_email])
      |> Map.put(:delay_ms, delay_ms)
      |> Map.put(:timeout_ms, timeout_ms)
    end

    test "fast path: step completes when action finishes before timeout" do
      run = create_run()
      params = timed_params(run, 0, 200)

      assert {:ok, result} = ActionWrapper.run(params, %{})
      assert is_list(result[:drafts])

      [ar] = Workflows.list_step_runs(run.id)
      assert ar.status == "completed"
    end

    test "slow path: returns {:error, :timeout} when action exceeds timeout" do
      run = create_run()
      params = timed_params(run, 250, 200)

      assert {:error, :timeout} = ActionWrapper.run(params, %{})
    end

    test "slow path: StepRun is marked failed with reason 'timeout'" do
      run = create_run()
      params = timed_params(run, 250, 200)

      ActionWrapper.run(params, %{})

      [ar] = Workflows.list_step_runs(run.id)
      assert ar.status == "failed"
      assert ar.errors["reason"] == "timeout"
      assert ar.finished_at != nil

      assert [%{"event" => "step_failed", "reason" => "timeout"}] = ar.logs
    end

    test "slow path: Logger.error is emitted on timeout" do
      run = create_run()
      params = timed_params(run, 250, 200)

      log =
        capture_log(fn ->
          ActionWrapper.run(params, %{})
        end)

      assert log =~ "[workflow] step timed out"
    end

    test "no timeout_ms in params: action runs directly without Task wrapping" do
      run = create_run()

      params =
        wp(run, DraftReplyStub, "draft", 0)
        |> Map.put(:emails, [@hardcoded_email])
        |> Map.put(:delay_ms, 0)

      assert {:ok, _} = ActionWrapper.run(params, %{})

      [ar] = Workflows.list_step_runs(run.id)
      assert ar.status == "completed"
    end
  end

  describe "run/2 — context injection" do
    setup do
      start_supervised!(ContextProbe)
      :ok
    end

    test "injects run_id and step_name into context before calling mod.run/2" do
      run = create_run()
      ActionWrapper.run(wp(run, ContextCaptureAction, "ctx_step", 2), %{})

      ctx = ContextProbe.get_context()
      assert ctx.run_id == run.id
      assert ctx.step_name == "ctx_step"
    end

    test "merges with existing context keys" do
      run = create_run()
      ActionWrapper.run(wp(run, ContextCaptureAction, "ctx_step", 0), %{extra: "val"})

      ctx = ContextProbe.get_context()
      assert ctx.run_id == run.id
      assert ctx.extra == "val"
    end

    test "injects the source_event actor into context" do
      source_event = %{
        "request" => nil,
        "assigns" => %{"trigger_type" => "event"},
        "trace_id" => Ecto.UUID.generate(),
        "actor" => %{"id" => "u1", "person_id" => 42, "name" => "alice"}
      }

      run = create_run_with_source_event(source_event)
      ActionWrapper.run(wp(run, ContextCaptureAction, "ctx_step", 0), %{})

      ctx = ContextProbe.get_context()
      assert ctx.actor["person_id"] == 42
      assert ctx.actor["name"] == "alice"
    end

    test "skip_permissions is true only with the explicit persisted flag" do
      source_event = %{
        "request" => nil,
        "assigns" => %{"trigger_type" => "manual", "skip_permissions" => true},
        "trace_id" => Ecto.UUID.generate()
      }

      run = create_run_with_source_event(source_event)
      ActionWrapper.run(wp(run, ContextCaptureAction, "ctx_step", 0), %{})

      ctx = ContextProbe.get_context()
      assert ctx.skip_permissions == true
    end

    test "skip_permissions defaults to false for an unflagged, actorless run" do
      run = create_run()
      ActionWrapper.run(wp(run, ContextCaptureAction, "ctx_step", 0), %{})

      ctx = ContextProbe.get_context()
      assert ctx.skip_permissions == false
      assert is_nil(ctx.actor)
    end
  end

  describe "run/2 — fetch_history end-to-end authorization" do
    alias Zaq.Accounts.People
    alias Zaq.Agent.Tools.Accounts.History
    alias Zaq.Engine.Conversations

    defp person_with_conversation do
      {:ok, person} =
        People.create_person(%{
          full_name: "Wrapped Person",
          email: "wrapped#{System.unique_integer([:positive])}@example.com"
        })

      {:ok, conv} =
        Conversations.create_conversation(%{
          channel_type: "bo",
          channel_user_id: "u_#{System.unique_integer([:positive])}",
          person_id: person.id
        })

      {:ok, _} = Conversations.add_message(conv, %{role: "user", content: "hello"})
      {person, conv}
    end

    test "flagged machine run may target a person via params" do
      {person, conv} = person_with_conversation()

      source_event = %{
        "request" => nil,
        "assigns" => %{"trigger_type" => "manual", "skip_permissions" => true},
        "trace_id" => Ecto.UUID.generate()
      }

      run = create_run_with_source_event(source_event)

      assert {:ok, result} =
               ActionWrapper.run(
                 wp(run, History, "history", 0) |> Map.put(:person_id, person.id),
                 %{}
               )

      assert [%{id: conv_id}] = result.conversations
      assert conv_id == conv.id

      [step_run] = Workflows.list_step_runs(run.id)
      assert step_run.status == "completed"
    end

    test "actor-carrying run recalls the actor's own conversations" do
      {person, conv} = person_with_conversation()

      source_event = %{
        "request" => nil,
        "assigns" => %{"trigger_type" => "event"},
        "trace_id" => Ecto.UUID.generate(),
        "actor" => %{"id" => "u1", "person_id" => person.id, "name" => "alice"}
      }

      run = create_run_with_source_event(source_event)

      assert {:ok, result} = ActionWrapper.run(wp(run, History, "history", 0), %{})
      assert [%{id: conv_id}] = result.conversations
      assert conv_id == conv.id
    end

    test "actorless unflagged run is unauthorized and the step fails" do
      {person, _conv} = person_with_conversation()
      run = create_run()

      assert {:error, _} =
               ActionWrapper.run(
                 wp(run, History, "history", 0) |> Map.put(:person_id, person.id),
                 %{}
               )

      [step_run] = Workflows.list_step_runs(run.id)
      assert step_run.status == "failed"
    end
  end
end
