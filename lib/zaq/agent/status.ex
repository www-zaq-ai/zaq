defmodule Zaq.Agent.Status do
  @moduledoc """
  Fire-and-forget PubSub broadcast for agent pipeline stage transitions.

  Any module holding an `%Incoming{}` struct or a status context map can call
  `broadcast/3` to emit `{:status_update, request_id, stage, message}` on the
  session PubSub topic that `ChatLive` subscribes to.

  A nil or incomplete context is silently ignored — missing context must never
  crash the pipeline.
  """

  alias Zaq.{Engine.Messages.Incoming, Event}

  @doc """
  Extracts session context from a `%Zaq.Event{}` for ETS registration in `StatusRegistry`.

  Returns `%{session_id, request_id, node_router}` when the event carries a valid
  `%Incoming{}` request with both fields present, or `nil` for a nil event or missing fields.
  Never raises.
  """
  @spec context_from_event(Event.t() | nil) :: map() | nil
  def context_from_event(%Event{request: %Incoming{metadata: meta}} = event) do
    session_id = meta[:session_id]
    request_id = meta[:request_id]

    if is_binary(session_id) and session_id != "" and
         is_binary(request_id) and request_id != "" do
      node_router = Keyword.get(event.opts, :node_router, Zaq.NodeRouter)
      %{session_id: session_id, request_id: request_id, node_router: node_router}
    else
      nil
    end
  end

  def context_from_event(_), do: nil

  @doc """
  Broadcasts a pipeline stage event to the originating chat session.

  Accepts an `%Incoming{}` struct, a plain map with `:session_id` and
  `:request_id` keys, or `nil`. Returns `:ok` immediately regardless of
  whether the broadcast succeeds — callers must not depend on delivery.

  The optional `node_router` argument defaults to `Zaq.NodeRouter`. Pass a
  test double to avoid real RPC in unit tests.
  """
  @spec broadcast(Incoming.t() | map() | nil, atom(), String.t(), module()) :: :ok
  def broadcast(context, stage, message, node_router \\ Zaq.NodeRouter)

  def broadcast(%Incoming{metadata: meta}, stage, message, node_router) do
    broadcast_to_session(meta[:session_id], meta[:request_id], stage, message, node_router)
  end

  def broadcast(%{session_id: session_id, request_id: request_id}, stage, message, node_router) do
    broadcast_to_session(session_id, request_id, stage, message, node_router)
  end

  def broadcast(nil, _stage, _message, _node_router), do: :ok

  defp broadcast_to_session(nil, _request_id, _stage, _message, _node_router), do: :ok
  defp broadcast_to_session(_session_id, nil, _stage, _message, _node_router), do: :ok

  defp broadcast_to_session(session_id, request_id, stage, message, node_router) do
    Event.new(
      %{
        module: Phoenix.PubSub,
        function: :broadcast,
        args: [Zaq.PubSub, "chat:#{session_id}", {:status_update, request_id, stage, message}]
      },
      :bo,
      type: :async
    )
    |> node_router.dispatch()

    :ok
  end
end
