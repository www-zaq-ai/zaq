defmodule Zaq.Channels.Events do
  @moduledoc """
  Standardized Channels role event builders and dispatchers.
  """

  alias Zaq.Engine.Messages.Outgoing
  alias Zaq.{Event, NodeRouter}
  alias Zaq.Events.Helper

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

  @spec build_upsert_message_event(Outgoing.t() | map(), keyword()) :: Event.t()
  def build_upsert_message_event(outgoing_or_params, opts \\ [])

  def build_upsert_message_event(%Outgoing{} = outgoing, opts) do
    event_type = resolve_upsert_event_type(outgoing, Keyword.get(opts, :type))
    event_opts = Keyword.get(opts, :event_opts, [])

    Event.new(outgoing, :channels,
      type: event_type,
      opts: [action: :upsert_message] ++ event_opts
    )
  end

  def build_upsert_message_event(params, opts) when is_map(params) do
    params
    |> map_to_outgoing()
    |> build_upsert_message_event(opts)
  end

  @spec build_and_dispatch_upsert_message_event(Outgoing.t() | map(), keyword()) :: Event.t()
  def build_and_dispatch_upsert_message_event(outgoing_or_params, opts \\ []) do
    build_upsert_message_event(outgoing_or_params, opts)
    |> node_router(opts).dispatch()
  end

  defp resolve_upsert_event_type(%Outgoing{} = outgoing, nil) do
    metadata = if is_map(outgoing.metadata), do: outgoing.metadata, else: %{}

    if Helper.present?(
         Map.get(metadata, :status_message_id) || Map.get(metadata, "status_message_id")
       ) do
      :async
    else
      :sync
    end
  end

  defp resolve_upsert_event_type(_params, type), do: type

  defp map_to_outgoing(params) do
    %Outgoing{
      provider: fetch(params, :provider),
      channel_id: fetch(params, :channel_id),
      thread_id: fetch(params, :thread_id),
      body: fetch(params, :body),
      metadata: %{
        request_id: fetch(params, :request_id),
        status_message_id: fetch(params, :status_message_id),
        update_intent: fetch(params, :update_intent),
        intent_meta: fetch(params, :intent_meta),
        session_id: fetch(params, :session_id),
        message_id: fetch(params, :message_id)
      }
    }
  end

  defp fetch(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp node_router(opts) do
    Keyword.get(opts, :node_router, NodeRouter)
  end
end
