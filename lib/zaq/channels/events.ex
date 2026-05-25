defmodule Zaq.Channels.Events do
  @moduledoc """
  Standardized Channels role event builders and dispatchers.
  """

  alias Zaq.Engine.Messages.Outgoing
  alias Zaq.{Event, NodeRouter}

  @spec build_deliver_outgoing_event(Outgoing.t(), keyword()) :: Event.t()
  def build_deliver_outgoing_event(%Outgoing{} = outgoing, opts \\ []) do
    event_type = Keyword.get(opts, :type, :sync)
    event_opts = Keyword.get(opts, :event_opts, [])

    Event.new(outgoing, :channels,
      type: event_type,
      opts: [action: :deliver_outgoing] ++ event_opts
    )
  end

  @spec build_and_dispatch_deliver_outgoing_event(Outgoing.t(), keyword()) :: Event.t()
  def build_and_dispatch_deliver_outgoing_event(%Outgoing{} = outgoing, opts \\ []) do
    build_deliver_outgoing_event(outgoing, opts)
    |> node_router(opts).dispatch()
  end

  @spec build_upsert_message_event(map(), keyword()) :: Event.t()
  def build_upsert_message_event(params, opts \\ []) when is_map(params) do
    event_type = resolve_upsert_event_type(params, Keyword.get(opts, :type))
    event_opts = Keyword.get(opts, :event_opts, [])

    Event.new(params, :channels, type: event_type, opts: [action: :upsert_message] ++ event_opts)
  end

  @spec build_and_dispatch_upsert_message_event(map(), keyword()) :: Event.t()
  def build_and_dispatch_upsert_message_event(params, opts \\ []) when is_map(params) do
    build_upsert_message_event(params, opts)
    |> node_router(opts).dispatch()
  end

  defp resolve_upsert_event_type(params, nil) do
    if present?(Map.get(params, :message_id) || Map.get(params, "message_id")) do
      :async
    else
      :sync
    end
  end

  defp resolve_upsert_event_type(_params, type), do: type

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value), do: not is_nil(value)

  defp node_router(opts) do
    Keyword.get(opts, :node_router, NodeRouter)
  end
end
