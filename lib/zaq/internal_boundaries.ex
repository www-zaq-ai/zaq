defmodule Zaq.InternalBoundaries do
  @moduledoc """
  Behaviour implemented by role-level API modules that receive routed events.
  """

  alias Zaq.Event

  @callback handle_event(Event.t(), atom(), map() | nil) :: Event.t()
end
