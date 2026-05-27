defmodule Zaq.Engine.TriggerNode do
  @moduledoc """
  Fires all active workflows associated with a trigger event_name, in parallel.

  Called by `Engine.EventRegistry` when a known trigger event is received.
  Queries `Workflows.list_workflows_for_trigger/1` for active workflows linked
  to the given event_name, then creates and starts a run for each in parallel
  via `Task.async_stream`.

  Propagates the triggering event's payload and trace_id into the run's
  `source_event.assigns.input`, making the event payload available as the
  initial fact for the starting node.

  Failures in individual workflow runs do not crash the TriggerNode call —
  errors are logged but do not propagate.
  """

  require Logger

  alias Zaq.Engine.Workflows
  alias Zaq.Event

  @spec fire(String.t(), map()) :: :ok
  def fire(event_name, event) when is_binary(event_name) do
    event_name
    |> Workflows.list_workflows_for_trigger()
    |> Task.async_stream(&run_workflow(&1, event),
      ordered: false,
      on_timeout: :kill_task,
      timeout: :infinity
    )
    |> Stream.run()

    :ok
  end

  defp run_workflow(workflow, incoming_event) do
    source_event = build_source_event(workflow, incoming_event)

    with {:ok, run} <- Workflows.create_run(workflow, source_event),
         {:ok, _completed_run} <- Workflows.start_run(run) do
      :ok
    else
      {:error, reason} ->
        Logger.error("TriggerNode: failed to run workflow #{workflow.id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp build_source_event(workflow, incoming_event) do
    trace_id =
      case incoming_event do
        %{trace_id: tid} when not is_nil(tid) -> tid
        _ -> Ecto.UUID.generate()
      end

    event =
      Event.new(
        %{trigger_type: :event, workflow_id: workflow.id},
        :engine,
        name: :workflow_run_triggered,
        trace_id: trace_id
      )

    input = build_input(incoming_event)

    %{event | assigns: %{trigger_type: :event, workflow_id: workflow.id, input: input}}
  end

  defp build_input(incoming_event) do
    Map.get(incoming_event, :request) || Map.get(incoming_event, "request") || %{}
  end
end
