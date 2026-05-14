defmodule Zaq.Engine.Workflows.Trigger.Type.Scheduler do
  @moduledoc """
  Trigger fired on a cron schedule. The Oban worker calls `TriggerExecutor.execute/3`
  with this trigger. Static input is read from `trigger.config["static_input"]` and
  merged with any caller-supplied input.
  """

  @behaviour Zaq.Engine.Workflows.Trigger.Behaviour

  alias Zaq.Event

  @impl true
  def fire(trigger, input) do
    static = Map.get(trigger.config || %{}, "static_input", %{})
    merged = Map.merge(static, input)

    {:ok,
     %Event{
       request: nil,
       next_hop: nil,
       trace_id: Ecto.UUID.generate(),
       assigns: %{trigger_type: :scheduler, input: merged}
     }}
  end

  @impl true
  def on_complete(_run, _step_runs), do: :ok
end
