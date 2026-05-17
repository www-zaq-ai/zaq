defmodule Zaq.Engine.TriggerNode do
  @moduledoc """
  Fires all active workflows associated with a trigger event_name, in parallel.

  Called by `Engine.EventRegistry` when a known trigger event is received.
  Queries `Workflows.list_workflows_for_trigger/1` for active workflows linked
  to the given event_name, then creates and starts a run for each in parallel
  via `Task.async_stream`.

  Failures in individual workflow runs do not crash the TriggerNode call —
  errors are logged but do not propagate.
  """

  require Logger

  alias Zaq.Engine.Workflows
  alias Zaq.Event

  @spec fire(String.t(), map()) :: :ok
  def fire(event_name, _event) when is_binary(event_name) do
    event_name
    |> Workflows.list_workflows_for_trigger()
    |> Task.async_stream(&run_workflow/1, ordered: false, on_timeout: :kill_task)
    |> Stream.run()

    :ok
  end

  defp run_workflow(workflow) do
    source_event = build_source_event(workflow)

    with {:ok, run} <- Workflows.create_run(workflow, source_event),
         {:ok, _completed_run} <- Workflows.start_run(run) do
      :ok
    else
      {:error, reason} ->
        Logger.error("TriggerNode: failed to run workflow #{workflow.id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp build_source_event(workflow) do
    Event.new(
      %{trigger_type: :event, workflow_id: workflow.id},
      :engine,
      name: :workflow_run_triggered
    )
  end
end
