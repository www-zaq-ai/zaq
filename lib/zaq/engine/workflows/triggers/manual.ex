defmodule Zaq.Engine.Workflows.Triggers.Manual do
  @moduledoc "Trigger fired explicitly by a user via the BO UI or API."

  @behaviour Zaq.Engine.Workflows.TriggerBehaviour

  alias Zaq.{Engine.Workflows, Event}

  @impl true
  def fire(_trigger, workflow, input) do
    event = %Event{
      request: nil,
      next_hop: nil,
      trace_id: Ecto.UUID.generate(),
      assigns: %{trigger_type: :manual, input: input}
    }

    Workflows.create_run(workflow, event)
  end

  @impl true
  def on_complete(_run, _action_results), do: :ok
end
