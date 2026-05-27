defmodule Zaq.Agent.Status do
  @moduledoc """
  Fire-and-forget intermediary status updates routed through Channels.

  Accepts `%Incoming{}` or `nil` as context input for `broadcast/4` and
  `broadcast/5`. A non-Incoming map raises `ArgumentError` by design,
  preventing status context drift. A `nil` or missing request id is silently
  ignored — missing context must never crash the pipeline.
  """

  alias Zaq.Channels.Events, as: ChannelEvents

  import Zaq.Engine.Messages,
    only: [is_present_message_id: 1, present_message_id?: 1, request_key: 2]

  alias Zaq.Engine.Messages.{Incoming, Outgoing}
  alias Zaq.Event

  @doc """
  Extracts session context from a `%Zaq.Event{}` for ETS registration in `StatusRegistry`.

  Returns `%{session_id, request_id, provider, channel_id, thread_id, node_router}` when the event carries a valid
  `%Incoming{}` request with a non-empty request id (metadata `:request_id` or
  incoming `:message_id`), or `nil` when missing.
  Never raises.
  """
  @spec context_from_event(Event.t() | nil) :: map() | nil
  def context_from_event(%Event{request: %Incoming{metadata: meta}} = event) do
    session_id = meta[:session_id]
    request_id = request_key(meta, event.request.message_id)

    if present_message_id?(request_id) do
      node_router = Keyword.get(event.opts, :node_router, Zaq.NodeRouter)

      %{
        session_id: session_id,
        request_id: request_id,
        provider: event.request.provider,
        channel_id: event.request.channel_id,
        thread_id: event.request.thread_id,
        node_router: node_router
      }
    else
      nil
    end
  end

  def context_from_event(_), do: nil

  @doc """
  Broadcasts a pipeline stage event to the originating chat session.

  For `%Incoming{}` inputs, returns the same incoming struct updated with
  `metadata[:status_message_id]` when the upsert call returns one.
  For `nil`, returns `nil`. Any non-Incoming context raises to prevent drift.
  """
  @spec broadcast(Incoming.t() | nil, atom(), String.t(), module()) :: Incoming.t() | nil
  @spec broadcast(Incoming.t() | nil, atom(), String.t(), module(), keyword()) ::
          Incoming.t() | nil

  def broadcast(context, stage, message, node_router) do
    broadcast(context, stage, message, node_router, [])
  end

  def broadcast(%Incoming{} = incoming, stage, message, node_router, opts) do
    outgoing =
      build_upsert_outgoing(
        %{
          session_id: incoming.metadata[:session_id],
          request_id: request_key(incoming.metadata, incoming.message_id),
          provider: incoming.provider,
          channel_id: incoming.channel_id,
          thread_id: incoming.thread_id,
          status_message_id: incoming.metadata[:status_message_id],
          update_intent: Keyword.get(opts, :update_intent)
        },
        stage,
        message
      )

    case dispatch_upsert(outgoing, node_router) do
      %Event{} = event -> merge_status_message_id(incoming, event)
      _ -> incoming
    end
  end

  def broadcast(%{} = _context, _stage, _message, _node_router, _opts) do
    raise ArgumentError,
          "Status.broadcast/5 requires %Incoming{} to avoid status context drift"
  end

  def broadcast(nil, _stage, _message, _node_router, _opts), do: nil

  defp dispatch_upsert(nil, _node_router), do: :ok

  defp dispatch_upsert(%Outgoing{} = outgoing, node_router) do
    ChannelEvents.build_and_dispatch_upsert_message_event(outgoing,
      node_router: node_router
    )
  end

  defp merge_status_message_id(%Incoming{} = incoming, %Event{response: response}) do
    case response do
      {:ok, %{message_id: message_id}} when is_present_message_id(message_id) ->
        metadata =
          incoming.metadata
          |> case do
            map when is_map(map) -> map
            _ -> %{}
          end
          |> Map.put(:status_message_id, message_id)

        %{incoming | metadata: metadata}

      _ ->
        incoming
    end
  end

  defp build_upsert_outgoing(%{} = context, stage, message) do
    request_id = Map.get(context, :request_id)
    provider = Map.get(context, :provider) || :web
    channel_id = Map.get(context, :channel_id) || "bo"

    if present_message_id?(request_id) do
      %Outgoing{
        provider: provider,
        channel_id: channel_id,
        thread_id: Map.get(context, :thread_id),
        body: message,
        metadata: %{
          request_id: request_id,
          status_message_id: Map.get(context, :status_message_id),
          update_intent: Map.get(context, :update_intent) || :status,
          session_id: Map.get(context, :session_id),
          intent_meta: %{stage: stage}
        }
      }
    else
      nil
    end
  end
end
