defmodule Zaq.TestSupport.NodeRouterPassthroughStub do
  @moduledoc false
  @behaviour Zaq.NodeRouter.Behaviour

  @impl true
  def find_node(_supervisor), do: nil

  @impl true
  def fire(%Zaq.Event{} = event), do: event

  @impl true
  def dispatch(%Zaq.Event{} = event), do: event

  @impl true
  def dispatch(%Zaq.Event{} = event, _runtime), do: event
end
