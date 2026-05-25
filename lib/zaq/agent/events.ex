defmodule Zaq.Agent.Events do
  @moduledoc """
  Standardized Agent role event builders and dispatchers.
  """

  alias Zaq.Event
  alias Zaq.Events.Helper

  @spec build_invoke_event(map(), atom(), keyword()) :: Event.t()
  def build_invoke_event(request, action, opts \\ []) when is_map(request) and is_atom(action) do
    Helper.build_invoke_event(:agent, request, action, opts)
  end

  @spec build_and_dispatch_invoke_event(map(), atom(), keyword()) :: Event.t()
  def build_and_dispatch_invoke_event(request, action, opts \\ [])
      when is_map(request) and is_atom(action) do
    Helper.build_and_dispatch_invoke_event(:agent, request, action, opts)
  end
end
