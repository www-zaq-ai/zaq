defmodule Zaq.Engine.Workflows.StepRunner do
  @moduledoc """
  Jido.Action runner injected by DagBuilder when a `run_id` option is provided.

  It runs the real workflow step module and writes one `StepRun` row per
  execution using the
  write-before / update-after crash-safe cursor pattern:

    1. `create_step_run` with `status: "running"` — written before the call.
    2. Delegates to the real action module.
    3. `complete_step_run` on `{:ok, result}` or `fail_step_run` on `{:error, _}`.

  If the wrapped module raises, the row is marked `"failed"` and the exception is
  re-raised — the StepRun is never left at `"running"`, and the caller receives the
  real exception rather than a hidden error tuple.

  ## Log trail

  `step_run.logs` always contains at minimum one timing entry as its first element:

  - `%{event: "step_completed", at: DateTime, duration_ms: non_neg_integer}` on success.
  - `%{event: "step_failed", at: DateTime, duration_ms: non_neg_integer, reason: string}` on failure.

  When the wrapped action returns a `{:ok, result, logs: action_logs}` 3-tuple,
  the step-level timing entry is prepended and the action logs follow.

  Wrapper keys (`wrapped_module`, `run_id`, `step_name`, `step_index`) are stripped
  from params before the wrapped module is called, so the wrapped module only sees
  its own domain params.

  ## Context injection

    Each step's context is enriched with `run_id`, `step_name`, `step_index`, the run's
    canonical `source_event.actor`, optional `source_event.request` as
    `source_request`, and `skip_permissions` — `true` only when `source_event.assigns` carries an
  explicit `skip_permissions: true` flag (set at run creation for machine/cron
  and BO manual runs), `false` otherwise. A missing actor never implies the
  bypass.

  ## Resume idempotency

  On resume after a pause, `run/2` checks for an existing `"completed"` `StepRun`
  row for `(run_id, step_name)`. If found, the stored results are returned
  immediately — no new row is created and the wrapped module is never called.
  This makes `WorkflowRunAgent.execute/2` safe to call on a paused run.
  """

  require Logger

  use Jido.Action, name: "workflow_step_runner", schema: []

  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.Action
  alias Zaq.Engine.Workflows.Conditions.ConditionNotMet
  alias Zaq.Engine.Workflows.Placeholders
  alias Zaq.Engine.Workflows.Step.Run, as: StepRun
  alias Zaq.Engine.Workflows.WorkflowRun

  @wrapper_keys [
    :wrapped_module,
    :run_id,
    :step_name,
    :step_index,
    :timeout_ms,
    :__placeholder_params__,
    :__field_specs__
  ]

  # Keys carried only to support `map` fan-out fork identity (see `Steps.MapExtract`).
  # `__map_index__` is stripped from the wrapped action's params but is used to name
  # the per-fork StepRun (`"<step>[i]"`) and is propagated into the result so a
  # multi-step body keeps the index across steps.
  @map_index_keys [:__map_index__, "__map_index__"]
  @map_strategy_keys [:__map_strategy__, "__map_strategy__"]
  # Keys stripped from the wrapped action's params (map plumbing, not domain data).
  @map_keys @map_index_keys ++ @map_strategy_keys ++ [:__map_item__, "__map_item__"]
  @max_retries 3

  @impl true
  def run(params, context) do
    %{wrapped_module: mod, run_id: run_id, step_index: step_index} = params
    map_index = first_present(params, @map_index_keys)
    strategy = first_present(params, @map_strategy_keys)

    step_name =
      fork_step_name(Map.get(params, :step_name) || Map.get(params, "step_name"), map_index)

    # An earlier body step in this fork already failed (isolated). Short-circuit the
    # rest of the fork: pass the `__map_error__` sentinel through untouched so no
    # further StepRun rows are written and exactly one fact still reaches the FanIn.
    # This is what makes multi-step map bodies isolate correctly.
    if map_error_input?(params) do
      {:ok, %{"__map_index__" => map_index, "__map_error__" => true}}
    else
      run_step(params, context, run_id, step_index, mod, map_index, strategy, step_name)
    end
  end

  defp map_error_input?(params),
    do: Map.get(params, "__map_error__") == true or Map.get(params, :__map_error__) == true

  defp run_step(params, context, run_id, step_index, mod, map_index, strategy, step_name) do
    case Workflows.get_run!(run_id).status do
      "paused" ->
        throw(:pause_requested)

      _ ->
        :ok
    end

    case Workflows.get_terminal_step_run(run_id, step_name) do
      %StepRun{status: "completed", results: results} ->
        Logger.debug("[workflow] step skipped — already completed on resume",
          run_id: run_id,
          step_name: step_name
        )

        {:ok, results || %{}}

      %StepRun{status: "failed", errors: errors} ->
        Logger.debug("[workflow] step skipped — already failed",
          run_id: run_id,
          step_name: step_name
        )

        {:error, errors}

      %StepRun{status: "skipped"} ->
        Logger.debug("[workflow] step skipped — condition already evaluated",
          run_id: run_id,
          step_name: step_name
        )

        {:error, :condition_not_met}

      %StepRun{status: "waiting"} ->
        Logger.debug("[workflow] step skipped — already waiting for approval",
          run_id: run_id,
          step_name: step_name
        )

        {:error, :waiting_for_human}

      nil ->
        execute_step(mod, run_id, step_name, step_index, params, context, map_index, strategy)
    end
  end

  defp first_present(params, keys), do: Enum.find_value(keys, &Map.get(params, &1))

  defp fork_step_name(name, nil), do: name
  defp fork_step_name(name, index), do: "#{name}[#{index}]"

  # A failed map fork is "isolated" (does not fail the whole run) under
  # :skip_and_continue / :retry. Such a fork is written with the `failed_fatal`
  # status — recorded for visibility, recovered by `MapCollect`, but ignored by
  # `finalize/2` (which only fails the run on `failed`/`running`). A non-isolated
  # fork (`:fail_workflow`) or any non-fork step keeps the plain `failed` status.
  defp isolated_fork?(nil, _strategy), do: false

  defp isolated_fork?(_index, strategy)
       when strategy in [:skip_and_continue, "skip_and_continue", :retry, "retry"],
       do: true

  defp isolated_fork?(_index, _strategy), do: false

  # The status written when a fork/step fails: `failed_fatal` for an isolated fork
  # (kept out of the run-fail check), plain `failed` otherwise.
  defp failure_status(map_index, strategy) do
    if isolated_fork?(map_index, strategy), do: "failed_fatal", else: "failed"
  end

  # Isolate-and-collect: an isolated map fork that fails must still emit a fact so the
  # FanIn reaches its fan-out cardinality and fires (otherwise the aggregate `MapCollect`
  # never runs and the failure is invisible). The error sentinel carries the fork index
  # and an `__map_error__` marker; the FanIn reducer drops it from `results`, and the
  # `failed_fatal` `StepRun` row (already written above) is where `MapCollect` recovers
  # the error. Non-isolated forks (`:fail_workflow`, or non-fork steps) propagate the error.
  defp fork_failure_return(err, map_index, strategy) do
    if isolated_fork?(map_index, strategy) do
      {:ok, %{"__map_index__" => map_index, "__map_error__" => true}}
    else
      err
    end
  end

  # Propagate the fan-out index into the result so the next body step (and the
  # reducer) can keep identifying the fork.
  defp put_map_index(result, nil), do: result

  defp put_map_index(result, index) when is_map(result),
    do: Map.put(result, "__map_index__", index)

  defp put_map_index(result, _index), do: result

  defp call_action(mod, action_params, context, nil) do
    mod.run(action_params, context)
  end

  defp call_action(mod, action_params, context, timeout_ms) do
    task = Task.async(fn -> mod.run(action_params, context) end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, :timeout}
    end
  end

  # Enforces the action's input schema once, ahead of the strategy — a wrong-kinded
  # param is not something a retry can fix.
  #
  # Until this, no action's declared schema was ever enforced at run time: this module
  # calls `mod.run/2` directly and never goes through `Jido.Exec`. So enforcement is
  # new for *every* action, judged through the NimbleOptions→Zoi translation in
  # `Action.field_specs/1` — which means a workflow authored against the old tolerance
  # can start failing on a value it used to survive, and a gap in the translation
  # becomes a failed run rather than a mis-reported contract.
  #
  # Refusing is the default, because a wrong-kinded param is a bug the run should not
  # paper over. `param_validation: :warn` is the escape hatch for a fleet whose stored
  # workflows have not been swept yet: the violation is logged with everything needed
  # to find the node, and the step runs as it did before.
  defp run_action(mod, params, context, timeout, strategy, step) do
    case validate_params(params, step.field_specs) do
      :ok ->
        call_with_strategy(mod, params, context, timeout, strategy)

      {:violations, reason} ->
        refuse_or_warn(mod, params, context, timeout, strategy, reason, step)
    end
  end

  defp refuse_or_warn(mod, params, context, timeout, strategy, reason, step) do
    case param_validation() do
      :warn ->
        Logger.warning("[workflow] #{reason}",
          run_id: step.run_id,
          step_name: step.step_name,
          module: inspect(mod)
        )

        call_with_strategy(mod, params, context, timeout, strategy)

      _error ->
        {:error, reason}
    end
  end

  defp param_validation do
    :zaq
    |> Application.get_env(Zaq.Engine.Workflows, [])
    |> Keyword.get(:param_validation, :error)
  end

  # Judges the params that are present, under either key form. Presence is
  # `InputContract`'s question, not this one.
  #
  # `specs` is read off the module once at DAG build time
  # (`DagBuilder.wrapper_params/5`) rather than here, because a `map` node runs this
  # for every item of its collection and the schema cannot differ between them. A
  # direct `StepRunner.run/2` call that carries no stamp falls back to reading it.
  defp validate_params(params, specs) do
    case Enum.flat_map(specs, &violation(&1, params)) do
      [] -> :ok
      violations -> {:violations, "Invalid parameters: " <> Enum.join(violations, "; ")}
    end
  end

  # One refusal line, phrased as `InputContract` phrases the same mismatch.
  defp violation({name, spec, _required?}, params) do
    case fetch_param(params, name) do
      {:ok, value} when not is_nil(value) ->
        case Zoi.parse(spec, value) do
          {:ok, _} ->
            []

          {:error, _} ->
            ["#{name}: expected #{Action.schema_kind(spec)}, got #{Action.value_kind(value)}"]
        end

      _ ->
        []
    end
  end

  defp fetch_param(params, name) do
    with :error <- Map.fetch(params, name) do
      Map.fetch(params, String.to_existing_atom(name))
    end
  rescue
    ArgumentError -> :error
  end

  # Under the :retry strategy a failing map fork is re-run up to @max_retries total
  # attempts before its outcome is written. Mirrors the old Batch/Iterate retry.
  defp call_with_strategy(mod, params, context, timeout, strategy)
       when strategy in [:retry, "retry"] do
    retry_call(mod, params, context, timeout, @max_retries)
  end

  defp call_with_strategy(mod, params, context, timeout, _strategy) do
    call_action(mod, params, context, timeout)
  end

  defp retry_call(mod, params, context, timeout, attempts_left) do
    case call_action(mod, params, context, timeout) do
      {:error, _} when attempts_left > 1 ->
        retry_call(mod, params, context, timeout, attempts_left - 1)

      other ->
        other
    end
  end

  defp inject_cascade(result, prev_cascade, step_name) when is_map(result) do
    Map.put(result, :__cascade__, Map.put(prev_cascade, step_name, result))
  end

  defp inject_cascade(result, _prev_cascade, _step_name), do: result

  # A binary error reason is already user-facing prose; keep it verbatim. Everything
  # else (atoms, tuples, exceptions) is inspected for a readable representation.
  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(reason), do: inspect(reason)

  # Resolves the `{{...}}` an author wrote in this node's params, so every action
  # receives literal values and none of them handles placeholders itself.
  #
  # The lookup fact is the params plus the run cascade, so a placeholder may name a
  # sibling param (`{{column_email}}`), an upstream node's result
  # (`{{extract_summary.output}}`), or the trigger payload (`{{start.language}}`).
  # Resolution is single-pass against the *unresolved* params, so a placeholder
  # whose value is itself a placeholder is not chased.
  #
  # `authored` comes from `DagBuilder.wrapper_params/5`, which scanned the static
  # params once at build time and kept the value the author wrote for each key that
  # carried a token. A node with none skips the walk entirely, and bulk data
  # delivered by an edge mapping is never traversed.
  #
  # Only a param still holding its authored value is resolved. An edge mapping whose
  # target collides with such a key wins the merge and delivers runtime data, which
  # is not author-written and so must reach the action verbatim — otherwise a
  # `{{...}}` a lead happened to type would be substituted as if the author had
  # written it.
  defp resolve_placeholders(action_params, authored, _prev_cascade)
       when map_size(authored) == 0,
       do: action_params

  defp resolve_placeholders(action_params, authored, prev_cascade) do
    case still_authored(action_params, authored) do
      unchanged when map_size(unchanged) == 0 ->
        action_params

      unchanged ->
        fact = Map.put(action_params, :__cascade__, prev_cascade)
        Map.merge(action_params, Placeholders.resolve(unchanged, fact, preserve_type: true))
    end
  end

  defp still_authored(action_params, authored) do
    for {key, value} <- authored,
        Map.get(action_params, key) === value,
        into: %{},
        do: {key, value}
  end

  defp execute_step(mod, run_id, step_name, step_index, params, context, map_index, strategy) do
    t0 = Action.log_start()

    Logger.debug("[workflow] step started",
      run_id: run_id,
      step_name: step_name,
      step_index: step_index,
      module: inspect(mod)
    )

    timeout_ms = Map.get(params, :timeout_ms)
    prev_cascade = Map.get(params, :__cascade__, Map.get(params, "__cascade__", %{}))
    placeholder_params = Map.get(params, :__placeholder_params__, %{})
    field_specs = Map.get(params, :__field_specs__) || Action.field_specs(mod)

    action_params =
      params
      |> Map.drop(@wrapper_keys ++ @map_keys ++ [:__cascade__, "__cascade__"])
      |> resolve_placeholders(placeholder_params, prev_cascade)

    {:ok, step_run} =
      Workflows.create_step_run(%WorkflowRun{id: run_id}, %{
        step_name: step_name,
        step_index: step_index,
        status: "running",
        input: json_safe(action_params)
      })

    enriched_context = enrich_context(context, run_id, step_name, step_index, prev_cascade)
    step = %{run_id: run_id, step_name: step_name, field_specs: field_specs}

    try do
      case run_action(mod, action_params, enriched_context, timeout_ms, strategy, step) do
        {:ok, result, logs: action_logs} ->
          cascaded = result |> inject_cascade(prev_cascade, step_name) |> put_map_index(map_index)
          step_log = Action.log_entry(:step_completed, t0)
          Workflows.complete_step_run(step_run, cascaded, [step_log | action_logs])
          Workflows.tick_log_summary(run_id)

          Logger.info("[workflow] step completed",
            run_id: run_id,
            step_name: step_name,
            step_index: step_index,
            duration_ms: System.monotonic_time(:millisecond) - t0
          )

          {:ok, cascaded}

        {:ok, result} ->
          cascaded = result |> inject_cascade(prev_cascade, step_name) |> put_map_index(map_index)
          step_log = Action.log_entry(:step_completed, t0)
          Workflows.complete_step_run(step_run, cascaded, [step_log])
          Workflows.tick_log_summary(run_id)

          Logger.info("[workflow] step completed",
            run_id: run_id,
            step_name: step_name,
            step_index: step_index,
            duration_ms: System.monotonic_time(:millisecond) - t0
          )

          {:ok, cascaded}

        {:error, :timeout} ->
          step_log = Action.log_entry(:step_failed, t0, %{reason: "timeout"})

          Workflows.fail_step_run(step_run, %{reason: "timeout"}, [step_log],
            status: failure_status(map_index, strategy)
          )

          Workflows.tick_log_summary(run_id)

          Logger.error("[workflow] step timed out timeout_ms=#{timeout_ms}",
            run_id: run_id,
            step_name: step_name,
            step_index: step_index,
            duration_ms: System.monotonic_time(:millisecond) - t0
          )

          fork_failure_return({:error, :timeout}, map_index, strategy)

        {:error, {:waiting_for_human, approval_token}} ->
          Workflows.wait_step_run(step_run)
          Workflows.tick_log_summary(run_id)

          Logger.info(
            "[workflow] step waiting for human approval approval_token=#{approval_token}",
            run_id: run_id,
            step_name: step_name
          )

          {:error, :waiting_for_human}

        {:error, reason} = err ->
          # A string reason (e.g. the Condition node's "Condition not met: …" sentence)
          # is already human-readable — store it verbatim so the run view shows it
          # cleanly. Only non-string reasons (atoms, tuples) are inspected.
          reason_text = reason_text(reason)
          step_log = Action.log_entry(:step_failed, t0, %{reason: reason_text})

          Workflows.fail_step_run(step_run, %{reason: reason_text}, [step_log],
            status: failure_status(map_index, strategy)
          )

          Workflows.tick_log_summary(run_id)

          Logger.error("[workflow] step failed",
            run_id: run_id,
            step_name: step_name,
            step_index: step_index,
            error: inspect(reason),
            duration_ms: System.monotonic_time(:millisecond) - t0
          )

          fork_failure_return(err, map_index, strategy)
      end
    rescue
      e in ConditionNotMet ->
        Workflows.skip_step_run(step_run, %{
          field: e.field,
          op: e.op,
          actual: e.actual,
          expected: e.expected
        })

        Workflows.tick_log_summary(run_id)

        Logger.info(
          "[workflow] condition not met — skipping branch field=#{e.field} op=#{e.op} actual=#{inspect(e.actual)}",
          run_id: run_id,
          step_name: step_name,
          step_index: step_index
        )

        reraise e, __STACKTRACE__

      e ->
        step_log = Action.log_entry(:step_failed, t0, %{reason: Exception.message(e)})
        Workflows.fail_step_run(step_run, %{reason: Exception.message(e)}, [step_log])
        Workflows.tick_log_summary(run_id)

        Logger.error("[workflow] step crashed",
          run_id: run_id,
          step_name: step_name,
          step_index: step_index,
          error: Exception.message(e),
          duration_ms: System.monotonic_time(:millisecond) - t0
        )

        reraise e, __STACKTRACE__
    end
  end

  defp enrich_context(context, run_id, step_name, step_index, prev_cascade) do
    source_event = run_id |> Workflows.get_run!() |> Map.get(:source_event)

    (context || %{})
    |> Map.merge(%{
      run_id: run_id,
      step_name: step_name,
      step_index: step_index,
      actor: source_event && source_event.actor,
      source_request: source_event && source_event.request,
      skip_permissions: skip_permissions?(source_event),
      # `__cascade__` is stripped from `action_params` (it is engine plumbing, not
      # a domain param) but exposed here so evaluation nodes like `Condition` can
      # resolve node-qualified (`step.field`) and `start.*` references via
      # `FactLookup`, exactly as `EdgeStep` does on edges.
      __cascade__: prev_cascade
    })
    |> Map.put(:node_router, Zaq.RuntimeDeps.workflow_step_node_router())
  end

  # Recursively converts action_params to a JSON-safe structure for Postgres JSONB.
  # Tuples (e.g. {Module, params} pipeline steps) become lists; atoms become strings.
  #
  # Temporal structs serialize to their ISO8601 string form (never the generic
  # `Map.from_struct` field-map) so date/datetime `Condition`s downstream can coerce
  # them via `DateOperand`. Mirrors `Zaq.Agent.StreamEvents.json_safe/1`.
  defp json_safe(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp json_safe(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_iso8601(ndt)
  defp json_safe(%Date{} = d), do: Date.to_iso8601(d)
  defp json_safe(%Time{} = t), do: Time.to_iso8601(t)

  defp json_safe(%_{} = struct) do
    struct |> Map.from_struct() |> json_safe()
  end

  defp json_safe(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {json_safe_key(k), json_safe(v)} end)
  end

  defp json_safe(list) when is_list(list), do: Enum.map(list, &json_safe/1)
  defp json_safe(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> json_safe()
  defp json_safe(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp json_safe(other), do: other

  defp json_safe_key(k) when is_atom(k), do: Atom.to_string(k)
  defp json_safe_key(k), do: k

  # The bypass must be an explicit flag persisted on the run's source_event
  # (string keys after the JSONB round-trip, atom keys in-process); anything
  # else — including a missing actor — means no bypass.
  defp skip_permissions?(%{assigns: assigns}) when is_map(assigns) do
    Map.get(assigns, :skip_permissions) == true or
      Map.get(assigns, "skip_permissions") == true
  end

  defp skip_permissions?(_), do: false
end
