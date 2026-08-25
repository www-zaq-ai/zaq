defmodule Zaq.Storage.Events do
  @moduledoc """
  Event builders for calls owned by the Storage role.
  """

  alias Zaq.{Event, NodeRouter}

  @doc "Builds a Storage event for the given action and request."
  @spec build_event(atom(), map(), keyword()) :: Event.t()
  def build_event(action, request, opts \\ []) when is_atom(action) and is_map(request) do
    event_opts =
      opts
      |> Keyword.get(:event_opts, Keyword.get(opts, :opts, []))
      |> Keyword.put(:action, action)
      |> maybe_put(:config, Keyword.get(opts, :config))

    event_new_opts =
      opts
      |> Keyword.drop([:node_router, :event_opts])
      |> Keyword.put(:opts, event_opts)

    request
    |> Event.new(:storage, event_new_opts)
  end

  @doc "Builds and dispatches a Storage event, returning the routed response."
  @spec build_and_dispatch_event(atom(), map(), keyword()) :: term()
  def build_and_dispatch_event(action, request, opts \\ []) do
    node_router = Keyword.get(opts, :node_router, NodeRouter)

    action
    |> build_event(request, opts)
    |> node_router.dispatch()
    |> Map.get(:response)
  end

  @doc "Builds a fixed disk materialization event for Storage."
  @spec build_materialize_document_event(map(), keyword()) :: Event.t()
  def build_materialize_document_event(request, opts \\ []) when is_map(request),
    do: build_event(:materialize_document, request, opts)

  @doc "Builds and dispatches a fixed disk materialization event for Storage."
  @spec build_and_dispatch_materialize_document_event(map(), keyword()) :: Event.t()
  def build_and_dispatch_materialize_document_event(request, opts \\ []) when is_map(request) do
    node_router = Keyword.get(opts, :node_router, NodeRouter)

    request
    |> build_materialize_document_event(opts)
    |> node_router.dispatch()
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
