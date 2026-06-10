defmodule Zaq.Engine.Workflows.ActionWrapper do
  @moduledoc """
  Transparent Jido.Action wrapper injected by DagBuilder when a `run_id` option
  is provided. Writes one `StepRun` row per step execution using the
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

  ## Resume idempotency

  On resume after a pause, `run/2` checks for an existing `"completed"` `StepRun`
  row for `(run_id, step_name)`. If found, the stored results are returned
  immediately — no new row is created and the wrapped module is never called.
  This makes `WorkflowAgent.execute/2` safe to call on a paused run.
  """

  require Logger

  use Jido.Action, name: "workflow_action_wrapper", schema: []

  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.Action
  alias Zaq.Engine.Workflows.Conditions.ConditionNotMet
  alias Zaq.Engine.Workflows.Step.Run, as: StepRun
  alias Zaq.Engine.Workflows.WorkflowRun

  @wrapper_keys [:wrapped_module, :run_id, :step_name, :step_index, :timeout_ms]

  @impl true
  def run(params, context) do
    %{wrapped_module: mod, run_id: run_id, step_name: step_name, step_index: step_index} = params

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
        execute_step(mod, run_id, step_name, step_index, params, context)
    end
  end

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

  defp inject_cascade(result, prev_cascade, step_name) when is_map(result) do
    Map.put(result, :__cascade__, Map.put(prev_cascade, step_name, result))
  end

  defp inject_cascade(result, _prev_cascade, _step_name), do: result

  defp execute_step(mod, run_id, step_name, step_index, params, context) do
    t0 = Action.log_start()

    Logger.debug("[workflow] step started",
      run_id: run_id,
      step_name: step_name,
      step_index: step_index,
      module: inspect(mod)
    )

    timeout_ms = Map.get(params, :timeout_ms)
    prev_cascade = Map.get(params, :__cascade__, Map.get(params, "__cascade__", %{}))
    action_params = Map.drop(params, @wrapper_keys ++ [:__cascade__, "__cascade__"])

    {:ok, step_run} =
      Workflows.create_step_run(%WorkflowRun{id: run_id}, %{
        step_name: step_name,
        step_index: step_index,
        status: "running",
        input: json_safe(action_params)
      })

    enriched_context = Map.merge(context || %{}, %{run_id: run_id, step_name: step_name})

    try do
      case call_action(mod, action_params, enriched_context, timeout_ms) do
        {:ok, result, logs: action_logs} ->
          cascaded = inject_cascade(result, prev_cascade, step_name)
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
          cascaded = inject_cascade(result, prev_cascade, step_name)
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
          Workflows.fail_step_run(step_run, %{reason: "timeout"}, [step_log])
          Workflows.tick_log_summary(run_id)

          Logger.error("[workflow] step timed out timeout_ms=#{timeout_ms}",
            run_id: run_id,
            step_name: step_name,
            step_index: step_index,
            duration_ms: System.monotonic_time(:millisecond) - t0
          )

          {:error, :timeout}

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
          step_log = Action.log_entry(:step_failed, t0, %{reason: inspect(reason)})
          Workflows.fail_step_run(step_run, %{reason: inspect(reason)}, [step_log])
          Workflows.tick_log_summary(run_id)

          Logger.error("[workflow] step failed",
            run_id: run_id,
            step_name: step_name,
            step_index: step_index,
            error: inspect(reason),
            duration_ms: System.monotonic_time(:millisecond) - t0
          )

          err
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

  # Recursively converts action_params to a JSON-safe structure for Postgres JSONB.
  # Tuples (e.g. {Module, params} pipeline steps) become lists; atoms become strings.
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
end
