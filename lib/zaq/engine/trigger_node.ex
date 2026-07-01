defmodule Zaq.Engine.TriggerNode do
  @moduledoc """
  Fires all active workflows associated with a trigger event_name, in parallel.

  Called by `Engine.EventRegistry` when a known trigger event is received.
  Queries `Workflows.list_workflows_for_trigger/1` for active workflows linked
  to the given event_name, then creates and starts a run for each in parallel
  via `Task.async_stream`.

  Propagates the triggering event's payload and trace_id into the run's
  `source_event.assigns.input`, making the event payload available as the
  initial fact for the starting node. The triggering event's `actor` is copied
  onto the `source_event` so steps can authorize against the person who caused
  the run; an explicit machine marker on the triggering event's `assigns` (set by
  the dispatcher — `DispatchEvent` or `CronTriggerWorker`) translates to
  `assigns.skip_permissions = true`. The marker is read from `assigns`, never the
  request payload, so a scalar payload can't crash the trigger — and a missing
  actor alone never grants the bypass.

  Failures in individual workflow runs do not crash the TriggerNode call —
  errors are logged but do not propagate.
  """

  require Logger

  alias Zaq.Engine.Workflows
  alias Zaq.Event
  alias Zaq.Identity.ActorNormalizer

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

    case Workflows.create_and_start_run(workflow, source_event) do
      {:ok, _completed_run} ->
        :ok

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

    %{
      event
      | actor: incoming_actor(incoming_event),
        assigns: %{
          trigger_type: :event,
          workflow_id: workflow.id,
          input: input,
          skip_permissions: machine_marked?(incoming_event)
        }
    }
  end

  defp build_input(incoming_event) do
    Map.get(incoming_event, :request) || Map.get(incoming_event, "request") || %{}
  end

  defp incoming_actor(incoming_event) do
    ActorNormalizer.from_event_request(incoming_event)
  end

  # The bypass requires an explicit machine marker on the event's `assigns`
  # (side-channel metadata set by the dispatcher — `DispatchEvent` /
  # `CronTriggerWorker`), never derived from the request payload. An absent
  # actor must never imply it (nil is not a grant), and only the boolean `true`
  # grants it. Reading `assigns` (not the request) means a scalar payload can
  # never crash the trigger.
  defp machine_marked?(%{assigns: assigns}) when is_map(assigns) do
    Map.get(assigns, :machine) == true or Map.get(assigns, "machine") == true
  end

  defp machine_marked?(_incoming_event), do: false
end
