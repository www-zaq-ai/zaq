defmodule Zaq.Bo.Api do
  @moduledoc """
  Back Office role boundary module used by `Zaq.NodeRouter.dispatch/1`.
  """

  @behaviour Zaq.InternalBoundaries

  alias Zaq.Event
  alias Zaq.InternalBoundaries

  @impl true
  def handle_event(%Event{} = event, action, _context),
    do: InternalBoundaries.default_handle_event(event, action)
end
