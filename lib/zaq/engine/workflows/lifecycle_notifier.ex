defmodule Zaq.Engine.Workflows.LifecycleNotifier do
  @moduledoc """
  Dispatches `:workflow` run-lifecycle events (`run.started`, `run.waiting`,
  `run.failed`, `run.incomplete`, `run.completed`) through `NodeRouter`.

  Lifecycle notification is observational: a subscriber that rejects, raises or
  exits must never take down the run that produced the event. Every failure mode
  is therefore contained here and logged, so both the run module (build-failure
  path) and `WorkflowRunAgent` (execution path) can notify without wrapping the
  call themselves.
  """

  require Logger

  alias Zaq.Event

  @doc """
  Dispatches `action` for `run` and swallows any dispatch failure.

  Returns the dispatch result on success, or `:ok` when the dispatch raised,
  exited or threw. Callers treat the return value as advisory.
  """
  @spec notify(String.t(), struct()) :: term()
  def notify(action, run) do
    result =
      %{action: action, run_id: run.id, workflow_id: run.workflow_id}
      |> Event.new(:engine,
        name: :workflow,
        actor: run.source_event && run.source_event.actor
      )
      |> node_router().dispatch()

    case result do
      %Event{response: {:error, reason}} -> log_failure(action, run, :error, reason)
      {:error, reason} -> log_failure(action, run, :error, reason)
      _ -> :ok
    end

    result
  rescue
    exception ->
      log_failure(action, run, :error, exception)
      :ok
  catch
    kind, reason ->
      log_failure(action, run, kind, reason)
      :ok
  end

  defp log_failure(action, run, kind, reason) do
    reason = if is_exception(reason), do: Exception.message(reason), else: inspect(reason)

    Logger.warning(
      "[workflow] lifecycle notification failed event_name=#{action} run_id=#{run.id} " <>
        "failure_kind=#{kind} reason=#{reason}"
    )
  end

  defp node_router, do: Application.get_env(:zaq, :node_router, Zaq.NodeRouter)
end
