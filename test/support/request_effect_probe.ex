defmodule Zaq.TestSupport.RequestEffectProbe do
  @moduledoc "Characterizes trusted Jido context and effects through the real Factory runtime."

  use Jido.Action,
    name: "request_effect_probe",
    description: "Observe native request context and emit a state effect",
    schema: Zoi.object(%{value: Zoi.string()})

  @impl true
  def run(%{value: value}, context) do
    send(context.test_pid, {:request_effect_context, context})

    {:ok, %{value: value},
     [%Jido.Agent.StateOp.SetPath{path: [:request_effect_probe], value: value}]}
  end
end
