defmodule Zaq.Engine.Workflows.Triggers.Signal do
  @moduledoc """
  Trigger fired when a matching Jido signal is emitted.
  The signal topic is stored in `trigger.config["topic"]`.
  """

  @behaviour Zaq.Engine.Workflows.TriggerBehaviour

  alias Zaq.Event

  @impl true
  def fire(_trigger, input) do
    {:ok,
     %Event{
       request: nil,
       next_hop: nil,
       trace_id: Ecto.UUID.generate(),
       assigns: %{trigger_type: :signal, input: input}
     }}
  end

  @impl true
  def on_complete(_run, _step_runs), do: :ok
end
