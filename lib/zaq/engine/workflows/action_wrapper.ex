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
  alias Zaq.Engine.Workflows.Conditions.ConditionNotMet
  alias Zaq.Engine.Workflows.Step.Run, as: StepRun
  alias Zaq.Engine.Workflows.WorkflowRun

  @wrapper_keys [:wrapped_module, :run_id, :step_name, :step_index]

  @impl true
  def run(params, context) do
    %{wrapped_module: mod, run_id: run_id, step_name: step_name, step_index: step_index} = params

    case Workflows.get_run!(run_id).status do
      "paused" ->
        throw(:pause_requested)

      _ ->
        :ok
    end

    case Workflows.get_completed_step_run(run_id, step_name) do
      %StepRun{results: results} ->
        Logger.debug("[workflow] step skipped — already completed on resume",
          run_id: run_id,
          step_name: step_name
        )

        {:ok, results || %{}}

      nil ->
        execute_step(mod, run_id, step_name, step_index, params, context)
    end
  end

  defp inject_cascade(result, prev_cascade, step_name) when is_map(result) do
    Map.put(result, :__cascade__, Map.put(prev_cascade, step_name, result))
  end

  defp inject_cascade(result, _prev_cascade, _step_name), do: result

  defp execute_step(mod, run_id, step_name, step_index, params, context) do
    started_ms = System.monotonic_time(:millisecond)

    Logger.debug("[workflow] step started",
      run_id: run_id,
      step_name: step_name,
      step_index: step_index,
      module: inspect(mod)
    )

    {:ok, step_run} =
      Workflows.create_step_run(%WorkflowRun{id: run_id}, %{
        step_name: step_name,
        step_index: step_index,
        status: "running"
      })

    prev_cascade = Map.get(params, :__cascade__, Map.get(params, "__cascade__", %{}))
    action_params = Map.drop(params, @wrapper_keys ++ [:__cascade__, "__cascade__"])

    try do
      case mod.run(action_params, context) do
        {:ok, result, logs: logs} ->
          cascaded = inject_cascade(result, prev_cascade, step_name)
          Workflows.complete_step_run(step_run, cascaded, logs)

          Logger.info("[workflow] step completed",
            run_id: run_id,
            step_name: step_name,
            step_index: step_index,
            duration_ms: System.monotonic_time(:millisecond) - started_ms
          )

          {:ok, cascaded}

        {:ok, result} ->
          cascaded = inject_cascade(result, prev_cascade, step_name)
          Workflows.complete_step_run(step_run, cascaded)

          Logger.info("[workflow] step completed",
            run_id: run_id,
            step_name: step_name,
            step_index: step_index,
            duration_ms: System.monotonic_time(:millisecond) - started_ms
          )

          {:ok, cascaded}

        {:error, reason} = err ->
          Workflows.fail_step_run(step_run, %{reason: inspect(reason)})

          Logger.error("[workflow] step failed",
            run_id: run_id,
            step_name: step_name,
            step_index: step_index,
            error: inspect(reason),
            duration_ms: System.monotonic_time(:millisecond) - started_ms
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

        Logger.info(
          "[workflow] condition not met — skipping branch field=#{e.field} op=#{e.op} actual=#{inspect(e.actual)}",
          run_id: run_id,
          step_name: step_name,
          step_index: step_index
        )

        reraise e, __STACKTRACE__

      e ->
        Workflows.fail_step_run(step_run, %{reason: Exception.message(e)})

        Logger.error("[workflow] step crashed",
          run_id: run_id,
          step_name: step_name,
          step_index: step_index,
          error: Exception.message(e),
          duration_ms: System.monotonic_time(:millisecond) - started_ms
        )

        reraise e, __STACKTRACE__
    end
  end
end
