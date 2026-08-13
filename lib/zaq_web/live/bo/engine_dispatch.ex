defmodule ZaqWeb.Live.BO.EngineDispatch do
  @moduledoc """
  Shared Back Office helper for dispatching Engine role events.
  """

  alias Zaq.{Event, NodeRouter}

  def dispatch(action, request \\ %{}) do
    Event.new(request, :engine, opts: [action: action])
    |> NodeRouter.dispatch()
    |> Map.get(:response)
  end
end
