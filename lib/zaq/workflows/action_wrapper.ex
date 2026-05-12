defmodule Zaq.Workflows.ActionWrapper do
  @moduledoc """
  Transparent Jido.Action wrapper injected by DagBuilder when a `run_id` option
  is provided. Writes one `ActionResult` row per step execution using the
  write-before / update-after crash-safe cursor pattern:

    1. `create_action_result` with `status: "running"` — written before the call.
    2. Delegates to the real action module.
    3. `complete_action_result` on `{:ok, result}` or `fail_action_result` on `{:error, _}`.

  If the wrapped module raises, the exception is caught, the row is marked `"failed"`,
  and `{:error, exception}` is returned — no crash cursor is left at `"running"`.

  Wrapper keys (`wrapped_module`, `run_id`, `step_name`, `step_index`) are stripped
  from params before the wrapped module is called, so the wrapped module only sees
  its own domain params.
  """

  use Jido.Action, name: "workflow_action_wrapper", schema: []

  alias Zaq.Workflows
  alias Zaq.Workflows.WorkflowRun

  @wrapper_keys [:wrapped_module, :run_id, :step_name, :step_index]

  @impl true
  def run(params, context) do
    %{wrapped_module: mod, run_id: run_id, step_name: step_name, step_index: step_index} = params

    {:ok, ar} =
      Workflows.create_action_result(%WorkflowRun{id: run_id}, %{
        step_name: step_name,
        step_index: step_index,
        status: "running"
      })

    action_params = Map.drop(params, @wrapper_keys)

    try do
      case mod.run(action_params, context) do
        {:ok, result} ->
          Workflows.complete_action_result(ar, result)
          {:ok, result}

        {:error, reason} = err ->
          Workflows.fail_action_result(ar, %{reason: inspect(reason)})
          err
      end
    rescue
      e ->
        Workflows.fail_action_result(ar, %{reason: Exception.message(e)})
        {:error, e}
    end
  end
end
