defmodule Zaq.Events.Helper do
  @moduledoc false

  alias Zaq.{Event, NodeRouter}

  @doc """
  Returns `true` if the value is considered "present".

  - For binaries: returns `true` if the trimmed string is not empty.
  - For all other values: returns `true` if not `nil`.
  """
  @spec present?(term()) :: boolean()
  def present?(value) when is_binary(value), do: String.trim(value) != ""

  def present?(value), do: not is_nil(value)

  @spec build_invoke_event(atom(), map(), atom(), keyword()) :: Event.t()
  def build_invoke_event(destination, request, action, opts \\ [])
      when is_atom(destination) and is_map(request) and is_atom(action) do
    event_type = Keyword.get(opts, :type, :sync)
    event_opts = Keyword.get(opts, :event_opts, [])

    Event.new(request, destination, type: event_type, opts: [action: action] ++ event_opts)
  end

  @spec build_and_dispatch_invoke_event(atom(), map(), atom(), keyword()) :: Event.t()
  def build_and_dispatch_invoke_event(destination, request, action, opts \\ [])
      when is_atom(destination) and is_map(request) and is_atom(action) do
    destination
    |> build_invoke_event(request, action, opts)
    |> node_router(opts).dispatch()
  end

  defp node_router(opts), do: Keyword.get(opts, :node_router, NodeRouter)
end
