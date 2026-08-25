defmodule Zaq.Engine.Workflows.StepRunnerTest do
  use Zaq.DataCase, async: true

  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.Conditions.ConditionNotMet
  alias Zaq.Engine.Workflows.DateOperand
  alias Zaq.Engine.Workflows.StepRunner

  import ExUnit.CaptureLog

  alias Zaq.Engine.Workflows.Test.{
    ContextCaptureAction,
    ContextProbe,
    DraftReplyStub,
    ErrorAction,
    OkAction,
    OkWithLogsAction,
    ParamCapture,
    ParamProbe,
    WaitingAction
  }

  setup do
    stub(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{} = event -> event end)
    :ok
  end

  @valid_workflow_attrs %{
    name: "StepRunner Test Workflow",
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

      assert {:ok, _} = StepRunner.run(wp(run, OkAction, "fetch", 0), %{})

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

      assert {:ok, result} = StepRunner.run(wp(run, OkAction, "step", 1), %{})
      assert result[:value] == "done"
      assert result[:__cascade__] == %{"step" => %{value: "done"}}
    end

    test "extra fields in params reach the wrapped module without error" do
      run = create_run()
      params = wp(run, OkAction, "step", 0) |> Map.put(:extra, "value")

      assert {:ok, _} = StepRunner.run(params, %{})
    end

    test "calls wrapped module returning 3-tuple with logs and writes completed StepRun" do
      run = create_run()

      assert {:ok, result} =
               StepRunner.run(wp(run, OkWithLogsAction, "fetch_logs", 0), %{})

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

  # Placeholder substitution lives here, not in the actions: `{{...}}` is resolved
  # once before the wrapped module is called, so every action receives literal
  # values and none of them implements substitution itself.
  describe "run/2 — placeholder resolution" do
    setup do
      start_supervised!(ParamCapture)
      :ok
    end

    # `__placeholder_params__` is what `DagBuilder.wrapper_params/5` stamps on at
    # build time — the authored value per placeholder-bearing key. These tests name
    # the keys and the helper stamps their values, the way the DAG would.
    defp wp_ph(run, step_name, params, keys, cascade \\ %{}) do
      run
      |> wp(ParamProbe, step_name, 0)
      |> Map.merge(params)
      |> Map.put(:__placeholder_params__, Map.take(params, keys))
      |> Map.put(:__cascade__, cascade)
    end

    test "resolves a placeholder from a sibling param" do
      run = create_run()

      assert {:ok, _} =
               StepRunner.run(
                 wp_ph(run, "build", %{input: "Sheet1!{{column}}", column: "L"}, [:input]),
                 %{}
               )

      assert ParamCapture.get_params()[:input] == "Sheet1!L"
    end

    test "resolves a node-qualified reference from the cascade" do
      run = create_run()

      params = %{input: "Summary: {{extract.output}}"}
      cascade = %{extract: %{output: "Acme builds rockets."}}

      assert {:ok, _} = StepRunner.run(wp_ph(run, "draft", params, [:input], cascade), %{})

      assert ParamCapture.get_params()[:input] == "Summary: Acme builds rockets."
    end

    test "resolves the start namespace" do
      run = create_run()

      params = %{input: "Reply in {{start.language}}"}
      cascade = %{start: %{"language" => "French"}}

      assert {:ok, _} = StepRunner.run(wp_ph(run, "draft", params, [:input], cascade), %{})

      assert ParamCapture.get_params()[:input] == "Reply in French"
    end

    test "descends a nested param path — the replacement for var flattening" do
      run = create_run()

      params = %{input: "Draft for {{row.name}}", row: %{"name" => "John Doe"}}

      assert {:ok, _} = StepRunner.run(wp_ph(run, "draft", params, [:input]), %{})

      assert ParamCapture.get_params()[:input] == "Draft for John Doe"
    end

    test "a bare key is not flattened out of a nested param map" do
      # `{{name}}` names no top-level key. It resolves to "" rather than reaching
      # into `row` — the author must write the path.
      run = create_run()

      params = %{input: "Draft for {{name}}", row: %{"name" => "John Doe"}}

      assert {:ok, _} = StepRunner.run(wp_ph(run, "draft", params, [:input]), %{})

      assert ParamCapture.get_params()[:input] == "Draft for "
    end

    test "resolves inside nested containers" do
      run = create_run()

      params = %{input: %{"topic" => ["{{subject}}"]}, subject: "rockets"}

      assert {:ok, _} = StepRunner.run(wp_ph(run, "dispatch", params, [:input]), %{})

      assert ParamCapture.get_params()[:input] == %{"topic" => ["rockets"]}
    end

    test "a whole-string placeholder keeps the raw value's type" do
      run = create_run()

      params = %{input: "{{rows}}", rows: [%{"a" => 1}]}

      assert {:ok, _} = StepRunner.run(wp_ph(run, "pass", params, [:input]), %{})

      assert ParamCapture.get_params()[:input] == [%{"a" => 1}]
    end

    test "an unresolved reference collapses to an empty string" do
      run = create_run()

      assert {:ok, _} =
               StepRunner.run(wp_ph(run, "draft", %{input: "[{{nope}}]"}, [:input]), %{})

      assert ParamCapture.get_params()[:input] == "[]"
    end

    test "only the keys named at build time are resolved" do
      # `other` carries a placeholder but is not in `__placeholder_params__`, so it is
      # never walked — this is what keeps a bulk payload off the resolver's path.
      run = create_run()

      params = %{input: "{{v}}", other: "{{v}}", v: "x"}

      assert {:ok, _} = StepRunner.run(wp_ph(run, "step", params, [:input]), %{})

      captured = ParamCapture.get_params()
      assert captured[:input] == "x"
      assert captured[:other] == "{{v}}"
    end

    test "a node with no placeholder keys passes its params through untouched" do
      run = create_run()

      params = %{input: "{{v}}", v: "x"}

      assert {:ok, _} = StepRunner.run(wp_ph(run, "step", params, []), %{})

      assert ParamCapture.get_params()[:input] == "{{v}}"
    end

    test "engine plumbing is never substitutable" do
      run = create_run()

      params = %{input: "[{{__cascade__}}][{{run_id}}]"}
      cascade = %{extract: %{output: "secret"}}

      assert {:ok, _} = StepRunner.run(wp_ph(run, "step", params, [:input], cascade), %{})

      assert ParamCapture.get_params()[:input] == "[][]"
    end

    test "the StepRun trace records the resolved input, not the template" do
      run = create_run()

      params = %{input: "Hello {{who}}", who: "world"}

      assert {:ok, _} = StepRunner.run(wp_ph(run, "greet", params, [:input]), %{})

      [step_run] = Workflows.list_step_runs(run.id)
      assert step_run.input["input"] == "Hello world"
    end

    test "resolves against string-keyed params — the stored-workflow shape" do
      # Params loaded from the `steps` JSONB arrive string-keyed, and the build-time
      # scan names them the same way. `FactLookup` reads either form.
      run = create_run()

      params = %{"input" => "Sheet1!{{column}}{{row}}", "column" => "L", "row" => 5}

      assert {:ok, _} = StepRunner.run(wp_ph(run, "build", params, ["input"]), %{})

      assert ParamCapture.get_params()["input"] == "Sheet1!L5"
    end

    test "a sibling param is addressable whatever the action's schema calls it" do
      # Actions used to exclude their own schema fields from substitution. The fact
      # is now uniformly every sibling param plus the cascade, and only `__*`
      # plumbing is off-limits — a field's name carries no special meaning here.
      run = create_run()

      params = %{input: "{{separator}}", separator: "-"}

      assert {:ok, _} = StepRunner.run(wp_ph(run, "build", params, [:input]), %{})

      assert ParamCapture.get_params()[:input] == "-"
    end

    test "`__placeholder_params__` never reaches the action" do
      run = create_run()

      assert {:ok, _} =
               StepRunner.run(wp_ph(run, "step", %{input: "{{v}}", v: "x"}, [:input]), %{})

      captured = ParamCapture.get_params()
      refute Map.has_key?(captured, :__placeholder_params__)
    end
  end

  describe "run/2 — JSON-safe serialization of temporal params" do
    # A prior step (e.g. `History`) hands a `%DateTime{}` down the cascade
    # (metadata.total.last_message_date). StepRunner json-safes step params for the
    # JSONB `input` column. The generic struct path (`Map.from_struct`) explodes a
    # DateTime into %{"calendar" => ..., "year" => ..., ...}, which `DateOperand`
    # cannot coerce — so a `type: "datetime"` Condition (check_last_message_date)
    # silently fails to compare. It must serialize to an ISO8601 string instead,
    # exactly as the sibling `StreamEvents.json_safe/1` already does.
    test "serializes a DateTime param as an ISO8601 string a date condition can consume" do
      run = create_run()
      dt = ~U[2026-07-08 12:57:29Z]

      ndt = ~N[2026-07-08 12:57:29]
      date = ~D[2026-07-08]
      time = ~T[12:57:29]

      params =
        run
        |> wp(OkAction, "check_last_message_date", 0)
        |> Map.merge(%{
          metadata: %{"total" => %{"last_message_date" => dt}},
          scheduled_for: ndt,
          due_on: date,
          starts_at: time,
          tuple_payload: {:ok, :queued}
        })

      assert {:ok, _} = StepRunner.run(params, %{})

      [ar] = Workflows.list_step_runs(run.id)
      serialized = ar.input["metadata"]["total"]["last_message_date"]

      # Must be a plain ISO8601 string — not the exploded struct field-map.
      assert serialized == "2026-07-08T12:57:29Z"

      # And that serialized form must round-trip through the date comparator used by
      # the `check_last_message_date` gate.
      assert {:ok, ^dt} = DateOperand.coerce_actual(serialized, "datetime")
      assert ar.input["scheduled_for"] == "2026-07-08T12:57:29"
      assert ar.input["due_on"] == "2026-07-08"
      assert ar.input["starts_at"] == "12:57:29"
      assert ar.input["tuple_payload"] == ["ok", "queued"]
    end
  end

  # `Jido.Exec` is what normally enforces an action's declared schema, and StepRunner
  # deliberately does not route through it — so without this gate nothing validates a
  # workflow's params at any point, and a wrong-typed value reaches `run/2`.
  describe "run/2 — param validation against the action's own schema" do
    alias Zaq.Engine.Workflows.Test.TypedParamAction

    defp typed_params(run, params),
      do: Map.merge(wp(run, TypedParamAction, "typed", 0), params)

    test "a wrong-typed param fails the step and the action is never entered" do
      run = create_run()

      assert {:error, _} = StepRunner.run(typed_params(run, %{count: "42"}), %{})
      refute_received {:typed_param_action_ran, _}

      [ar] = Workflows.list_step_runs(run.id)
      assert ar.status == "failed"
    end

    test "the failure reason names the offending field" do
      run = create_run()

      assert {:error, _} = StepRunner.run(typed_params(run, %{count: "42"}), %{})

      [ar] = Workflows.list_step_runs(run.id)
      assert ar.errors["reason"] =~ "count"
    end

    test "a correctly-typed param runs and reaches the action" do
      run = create_run()

      assert {:ok, result} = StepRunner.run(typed_params(run, %{count: 42}), %{})
      assert_received {:typed_param_action_ran, _}
      assert result.count == 42

      [ar] = Workflows.list_step_runs(run.id)
      assert ar.status == "completed"
    end

    # Validation is a verdict, not a rewrite. The action receives exactly the params it
    # always did — schema defaults and casts are not injected, because changing what
    # every action receives is a far wider change than closing the validation hole.
    test "the action receives the params it was given, not a validated rewrite" do
      run = create_run()

      assert {:ok, result} = StepRunner.run(typed_params(run, %{count: 1}), %{})
      assert result.label == nil
    end

    # Workflow params are mixed-key by construction: static params are atomized while
    # the trigger payload and edge mappings stay string-keyed, and actions read both.
    # A string-keyed required field must satisfy the schema, not read as absent.
    test "a string-keyed param satisfies its schema field" do
      run = create_run()

      assert {:ok, _} = StepRunner.run(typed_params(run, %{"count" => 7}), %{})
      assert_received {:typed_param_action_ran, params}
      assert params["count"] == 7
    end

    test "a string-keyed param of the wrong kind still fails" do
      run = create_run()

      assert {:error, _} = StepRunner.run(typed_params(run, %{"count" => "7"}), %{})
      refute_received {:typed_param_action_ran, _}
    end

    # Validation must not become a filter: fact overflow and mapped data that no schema
    # names still has to reach the action, exactly as it does today.
    test "keys the schema does not name still reach the action" do
      run = create_run()

      assert {:ok, result} =
               StepRunner.run(typed_params(run, %{count: 1, extra: "carried"}), %{})

      assert result.extra == "carried"
    end

    test "an action declaring an empty schema is unaffected" do
      run = create_run()

      assert {:ok, _} = StepRunner.run(wp(run, OkAction, "fetch", 0), %{})
    end

    # Validation is deterministic, so a retry strategy must not spend attempts on it.
    test "a wrong-typed param is not retried" do
      run = create_run()

      params =
        run
        |> typed_params(%{count: "42"})
        |> Map.put(:__map_strategy__, :retry)

      assert {:error, _} = StepRunner.run(params, %{})
      refute_received {:typed_param_action_ran, _}
    end
  end

  describe "run/2 — error path" do
    test "calls wrapped module and writes failed ActionResult" do
      run = create_run()

      assert {:error, :test_failure} = StepRunner.run(wp(run, ErrorAction, "draft", 1), %{})

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

      assert {:error, :test_failure} = StepRunner.run(wp(run, ErrorAction, "step", 0), %{})
    end
  end

  describe "run/2 — wrapper fields are stripped from ActionResult results" do
    test "wrapper keys do not appear in completed results" do
      run = create_run()
      StepRunner.run(wp(run, OkAction, "fetch", 0), %{})

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
        StepRunner.run(wp(run, RaisingAction, "step", 0), %{})
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

      result = StepRunner.run(wp(run, CountingAction, "fetch", 0), %{})
      assert {:ok, %{"cached" => true}} = result
      assert :counters.get(call_count, 1) == 0, "wrapped module must not be called on resume"
    end

    test "does not insert a new StepRun row when step is already completed" do
      run = create_run()

      {:ok, sr} =
        Workflows.create_step_run(run, %{step_name: "fetch", step_index: 0, status: "running"})

      {:ok, _} = Workflows.complete_step_run(sr, %{value: "original"})

      StepRunner.run(wp(run, OkAction, "fetch", 0), %{})

      rows = Workflows.list_step_runs(run.id)
      assert length(rows) == 1, "must not create a duplicate StepRun on resume"
    end

    test "returns empty map when completed step has nil results" do
      run = create_run()

      {:ok, sr} =
        Workflows.create_step_run(run, %{step_name: "fetch", step_index: 0, status: "running"})

      Workflows.complete_step_run(sr, nil)

      assert {:ok, %{}} = StepRunner.run(wp(run, OkAction, "fetch", 0), %{})
    end

    test "runs normally when no completed StepRun exists" do
      run = create_run()
      assert {:ok, %{value: "done"}} = StepRunner.run(wp(run, OkAction, "fetch", 0), %{})

      [ar] = Workflows.list_step_runs(run.id)
      assert ar.status == "completed"
    end
  end

  describe "run/2 — cascade accumulation" do
    test "first step: no prior cascade → result contains cascade with this step only" do
      run = create_run()

      assert {:ok, result} = StepRunner.run(wp(run, OkAction, "step_a", 0), %{})
      assert result[:__cascade__] == %{"step_a" => %{value: "done"}}
    end

    test "second step: receives prior cascade → result extends it" do
      run = create_run()
      prior_cascade = %{"step_a" => %{value: "from_a"}}
      params = wp(run, OkAction, "step_b", 1) |> Map.put(:__cascade__, prior_cascade)

      assert {:ok, result} = StepRunner.run(params, %{})

      assert result[:__cascade__] == %{
               "step_a" => %{value: "from_a"},
               "step_b" => %{value: "done"}
             }
    end

    test "string-keyed __cascade__ (JSONB resume path) is read and extended" do
      run = create_run()
      prior_cascade = %{"step_a" => %{"value" => "from_a"}}
      params = wp(run, OkAction, "step_b", 1) |> Map.put("__cascade__", prior_cascade)

      assert {:ok, result} = StepRunner.run(params, %{})
      assert result[:__cascade__]["step_a"] == %{"value" => "from_a"}
      assert result[:__cascade__]["step_b"] == %{value: "done"}
    end

    test "failed step does not update the cascade" do
      run = create_run()
      prior_cascade = %{"step_a" => %{value: "from_a"}}
      params = wp(run, ErrorAction, "step_b", 1) |> Map.put(:__cascade__, prior_cascade)

      assert {:error, :test_failure} = StepRunner.run(params, %{})

      [ar] = Workflows.list_step_runs(run.id)
      assert ar.status == "failed"
      refute Map.has_key?(ar.errors || %{}, "__cascade__")
    end

    test "cascade is stored in StepRun results so resume recovers it" do
      run = create_run()
      prior_cascade = %{"step_a" => %{value: "from_a"}}
      params = wp(run, OkAction, "step_b", 1) |> Map.put(:__cascade__, prior_cascade)

      StepRunner.run(params, %{})

      [ar] = Workflows.list_step_runs(run.id)
      assert ar.results["__cascade__"]["step_a"] == %{"value" => "from_a"}
      assert ar.results["__cascade__"]["step_b"] == %{"value" => "done"}
    end

    test "scalar action result is returned without cascade or map index injection" do
      defmodule ScalarAction do
        @moduledoc false
        use Jido.Action, name: "scalar_action_aw", schema: []

        def run(_params, _context), do: {:ok, "scalar-result"}
      end

      run = create_run()

      params =
        run
        |> wp(ScalarAction, "scalar_step", 1)
        |> Map.put(:__cascade__, %{"previous" => %{value: "done"}})
        |> Map.put(:__map_index__, 7)

      assert {:ok, "scalar-result"} = StepRunner.run(params, %{})
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

      assert {:ok, result} = StepRunner.run(params, %{})
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
        StepRunner.run(wp(run, ConditionRaisingAction, "cond_step", 0), %{})
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
               StepRunner.run(wp(run, WaitingAction, "hitl_step", 0), %{})

      [ar] = Workflows.list_step_runs(run.id)
      assert ar.status == "waiting"
      assert ar.step_name == "hitl_step"
    end

    test "does not mark StepRun as failed when step returns waiting_for_human" do
      run = create_run()
      StepRunner.run(wp(run, WaitingAction, "review", 0), %{})

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

      assert {:error, _} = StepRunner.run(wp(run, OkAction, "draft", 1), %{})

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

      StepRunner.run(wp(run, NeverCalledAction, "draft", 1), %{})
      assert :counters.get(call_count, 1) == 0, "wrapped module must not be called on retry"
    end

    test "returns {:error, :condition_not_met} without re-executing when step is already skipped" do
      run = create_run()

      {:ok, sr} =
        Workflows.create_step_run(run, %{step_name: "edge", step_index: 0, status: "running"})

      {:ok, _} =
        Workflows.skip_step_run(sr, %{field: "count", op: "gt", actual: 0, expected: 5})

      assert {:error, :condition_not_met} = StepRunner.run(wp(run, OkAction, "edge", 0), %{})

      rows = Workflows.list_step_runs(run.id)
      assert length(rows) == 1, "must not create a duplicate StepRun"
    end

    test "returns {:error, :waiting_for_human} without re-executing when step is already waiting" do
      run = create_run()

      {:ok, sr} =
        Workflows.create_step_run(run, %{step_name: "hitl", step_index: 1, status: "running"})

      {:ok, _} = Workflows.wait_step_run(sr)

      assert {:error, :waiting_for_human} = StepRunner.run(wp(run, OkAction, "hitl", 1), %{})

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

      assert {:ok, result} = StepRunner.run(params, %{})
      assert is_list(result[:drafts])

      [ar] = Workflows.list_step_runs(run.id)
      assert ar.status == "completed"
    end

    test "slow path: returns {:error, :timeout} when action exceeds timeout" do
      run = create_run()
      params = timed_params(run, 250, 200)

      assert {:error, :timeout} = StepRunner.run(params, %{})
    end

    test "slow path: StepRun is marked failed with reason 'timeout'" do
      run = create_run()
      params = timed_params(run, 250, 200)

      StepRunner.run(params, %{})

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
          StepRunner.run(params, %{})
        end)

      assert log =~ "[workflow] step timed out"
    end

    test "no timeout_ms in params: action runs directly without Task wrapping" do
      run = create_run()

      params =
        wp(run, DraftReplyStub, "draft", 0)
        |> Map.put(:emails, [@hardcoded_email])
        |> Map.put(:delay_ms, 0)

      assert {:ok, _} = StepRunner.run(params, %{})

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
      StepRunner.run(wp(run, ContextCaptureAction, "ctx_step", 2), %{})

      ctx = ContextProbe.get_context()
      assert ctx.run_id == run.id
      assert ctx.step_name == "ctx_step"
    end

    test "merges with existing context keys" do
      run = create_run()
      StepRunner.run(wp(run, ContextCaptureAction, "ctx_step", 0), %{extra: "val"})

      ctx = ContextProbe.get_context()
      assert ctx.run_id == run.id
      assert ctx.extra == "val"
    end

    test "injects the source_event request into context as source_request" do
      source_event = %{
        "request" => %{"person" => %{"id" => 42}},
        "assigns" => %{"trigger_type" => "event"},
        "trace_id" => Ecto.UUID.generate()
      }

      run = create_run_with_source_event(source_event)
      StepRunner.run(wp(run, ContextCaptureAction, "ctx_step", 0), %{})

      ctx = ContextProbe.get_context()
      assert ctx.source_request["person"]["id"] == 42
      assert is_nil(ctx.actor)
    end

    test "skip_permissions is true only with the explicit persisted flag" do
      source_event = %{
        "request" => nil,
        "assigns" => %{"trigger_type" => "manual", "skip_permissions" => true},
        "trace_id" => Ecto.UUID.generate()
      }

      run = create_run_with_source_event(source_event)
      StepRunner.run(wp(run, ContextCaptureAction, "ctx_step", 0), %{})

      ctx = ContextProbe.get_context()
      assert ctx.skip_permissions == true
    end

    test "skip_permissions defaults to false for an unflagged, actorless run" do
      run = create_run()
      StepRunner.run(wp(run, ContextCaptureAction, "ctx_step", 0), %{})

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
               StepRunner.run(
                 wp(run, History, "history", 0) |> Map.put(:person_id, person.id),
                 %{}
               )

      assert [%{id: conv_id}] = result.conversations
      assert conv_id == conv.id

      [step_run] = Workflows.list_step_runs(run.id)
      assert step_run.status == "completed"
    end

    test "actor-person run recalls the actor person's own conversations" do
      {person, conv} = person_with_conversation()

      source_event = %{
        "actor" => %{"person" => %{"id" => person.id}},
        "request" => %{},
        "assigns" => %{"trigger_type" => "event"},
        "trace_id" => Ecto.UUID.generate()
      }

      run = create_run_with_source_event(source_event)

      assert {:ok, result} = StepRunner.run(wp(run, History, "history", 0), %{})
      assert [%{id: conv_id}] = result.conversations
      assert conv_id == conv.id
    end

    test "actorless unflagged run is unauthorized and the step fails" do
      {person, _conv} = person_with_conversation()
      run = create_run()

      assert {:error, _} =
               StepRunner.run(
                 wp(run, History, "history", 0) |> Map.put(:person_id, person.id),
                 %{}
               )

      [step_run] = Workflows.list_step_runs(run.id)
      assert step_run.status == "failed"
    end
  end
end
