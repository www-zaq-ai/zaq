defmodule Zaq.Engine.Workflows.CronTriggerWorker do
  @moduledoc """
  Oban worker that fires a cron-based workflow trigger.

  Each enabled `Trigger` with `trigger_type: "cron"` has its `cron_schedule`
  registered in `Zaq.Oban.DynamicCron` with this worker. On fire it dispatches
  a `%Zaq.Event{}` for the trigger's `event_name` via `NodeRouter.dispatch/1`,
  so the existing `EventRegistry → TriggerNode` path starts workflow runs
  identically to any other event trigger.

  Safe discards (`:ok` with no dispatch):
  - Trigger not found in DB (deleted between registration and fire).
  - Trigger is disabled.
  - Trigger has `trigger_type` other than `"cron"` (defensive guard).
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  alias Zaq.Engine.Workflows
  alias Zaq.Event

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"trigger_id" => trigger_id}}) do
    case Workflows.get_trigger(trigger_id) do
      nil ->
        :ok

      %{enabled: false} ->
        :ok

      %{trigger_type: type} when type != "cron" ->
        :ok

      trigger ->
        Event.new(
          %{trigger_id: trigger.id},
          :engine,
          name: trigger.event_name
        )
        |> node_router().dispatch()

        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp node_router,
    do: Application.get_env(:zaq, :node_router, Zaq.NodeRouter)
end
