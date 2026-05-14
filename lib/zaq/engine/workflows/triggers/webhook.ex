defmodule Zaq.Engine.Workflows.Triggers.Webhook do
  @moduledoc "Trigger fired by an authenticated HTTP POST to `/webhooks/triggers/:id`."

  @behaviour Zaq.Engine.Workflows.TriggerBehaviour

  alias Zaq.Event

  @impl true
  def fire(_trigger, input) do
    {:ok,
     %Event{
       request: nil,
       next_hop: nil,
       trace_id: Ecto.UUID.generate(),
       assigns: %{trigger_type: :webhook, input: input}
     }}
  end

  @impl true
  def on_complete(_run, _step_runs), do: :ok
end
