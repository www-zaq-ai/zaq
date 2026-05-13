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
  """

  require Logger

  use Jido.Action, name: "workflow_action_wrapper", schema: []

  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.WorkflowRun

  @wrapper_keys [:wrapped_module, :run_id, :step_name, :step_index]

  @impl true
  def run(params, context) do
    %{wrapped_module: mod, run_id: run_id, step_name: step_name, step_index: step_index} = params
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

    action_params = Map.drop(params, @wrapper_keys)

    try do
      case mod.run(action_params, context) do
        {:ok, result, logs: logs} ->
          Workflows.complete_step_run(step_run, result, logs)

          Logger.info("[workflow] step completed",
            run_id: run_id,
            step_name: step_name,
            step_index: step_index,
            duration_ms: System.monotonic_time(:millisecond) - started_ms
          )

          {:ok, result}

        {:ok, result} ->
          Workflows.complete_step_run(step_run, result)

          Logger.info("[workflow] step completed",
            run_id: run_id,
            step_name: step_name,
            step_index: step_index,
            duration_ms: System.monotonic_time(:millisecond) - started_ms
          )

          {:ok, result}

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
