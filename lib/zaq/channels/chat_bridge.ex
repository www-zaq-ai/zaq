defmodule Zaq.Channels.ChatBridge do
  @moduledoc """
  Bridge for the ChatVote `:chat` channel (OpenAI-compatible HTTP endpoint).

  Unlike push transports, the chat channel is a synchronous HTTP request:
  `ZaqWeb.ChatCompletionsController` subscribes to `topic/1` BEFORE routing the
  incoming message through `CommunicationBridge.route_incoming_message/5` (so
  the request flows through `NodeRouter.dispatch/1` like every other bridge —
  traces, person resolution and persistence come from the shared pipeline), and
  `send_reply/2` delivers the pipeline `%Outgoing{}` back to that waiting
  request process over PubSub.
  """

  @behaviour Zaq.Channels.Bridge
  @behaviour Zaq.Channels.CommunicationBridge

  alias Zaq.Engine.Messages.{Incoming, Outgoing}

  @doc """
  Builds `%Incoming{provider: :chat}` from controller params.

  Expected keys: `:content` (the clean user question — this is what gets
  persisted), `:conversation_id`, `:author_id` (the caller's authenticated
  Supabase user id — also the Person channel identity), `:message_id` (request
  correlation id echoed back on `send_reply/2`), `:source_filter` (list of
  source prefixes retrieval is restricted to; `[]`/`nil` means unrestricted).
  """
  @spec to_internal(map(), map()) :: Incoming.t()
  @impl true
  def to_internal(params, _connection_details \\ %{}) do
    Incoming.new(%{
      content: params[:content],
      channel_id: params[:conversation_id],
      author_id: params[:author_id],
      message_id: params[:message_id],
      provider: :chat,
      content_filter: params[:source_filter] || [],
      metadata: %{conversation_id: params[:conversation_id]}
    })
  end

  @doc """
  Delivers the pipeline result to the waiting HTTP request process.

  The message shape is `{:chat_result, request_id, outgoing}` where
  `request_id` is the `message_id` the controller stamped on the `%Incoming{}`
  (carried back as `outgoing.in_reply_to`), so concurrent requests on the same
  conversation each pick up their own result.
  """
  @spec send_reply(Outgoing.t(), map()) :: :ok | {:error, term()}
  @impl true
  def send_reply(%Outgoing{} = outgoing, _connection_details) do
    Phoenix.PubSub.broadcast(
      Zaq.PubSub,
      topic(outgoing.channel_id),
      {:chat_result, outgoing.in_reply_to, outgoing}
    )
  end

  @doc "PubSub topic the controller subscribes to for a conversation."
  @spec topic(String.t()) :: String.t()
  def topic(conversation_id), do: "chat:conv:#{conversation_id}"

  # Progressive streaming: the executor's `StreamEvents` flushes the answer's
  # cumulative text as `:stream_delta` upserts (~10/s). Forward them to the
  # waiting request process so the controller can emit OpenAI SSE deltas while
  # the LLM is still generating. The broadcast body is CUMULATIVE per LLM-call
  # segment — the controller diffs it against what it already sent. Other
  # intents (`:status`, `:reasoning`, `:tool_call`) have no surface on the
  # OpenAI wire: accept and drop, like the WebBridge fallback branch.
  @impl true
  def upsert_message(_config, request, _connection_details) when is_map(request) do
    update_intent = Map.get(request, :update_intent)
    request_id = Map.get(request, :request_id)
    channel_id = Map.get(request, :channel_id)
    body = Map.get(request, :body)

    if stream_delta?(update_intent) and is_binary(body) and present?(request_id) and
         present?(channel_id) do
      Phoenix.PubSub.broadcast(
        Zaq.PubSub,
        topic(channel_id),
        {:chat_stream_delta, request_id, body}
      )
    end

    {:ok, %{action: :noop, message_id: nil, update_intent: update_intent}}
  end

  defp stream_delta?(intent), do: intent in [:stream_delta, "stream_delta"]

  defp present?(value), do: is_binary(value) and value != ""
end
