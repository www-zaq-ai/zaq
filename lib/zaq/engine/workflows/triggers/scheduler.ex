defmodule Zaq.Engine.Workflows.Triggers.Scheduler do
  @moduledoc """
  Trigger fired on a cron schedule. The Oban worker calls `fire/3` directly.
  Static input is read from `trigger.config["static_input"]` and merged with
  any caller-supplied input.
  """

  @behaviour Zaq.Engine.Workflows.TriggerBehaviour

  alias Zaq.{Engine.Workflows, Event}

  @impl true
  def fire(trigger, workflow, input) do
    static = Map.get(trigger.config || %{}, "static_input", %{})
    merged = Map.merge(static, input)

    event = %Event{
      request: nil,
      next_hop: nil,
      trace_id: Ecto.UUID.generate(),
      assigns: %{trigger_type: :scheduler, input: merged}
    }

    Workflows.create_run(workflow, event)
  end

  @impl true
  def on_complete(_run, _action_results), do: :ok
end
