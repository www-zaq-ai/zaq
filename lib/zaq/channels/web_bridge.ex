defmodule Zaq.Channels.WebBridge do
  @moduledoc """
  Bridge for the web (ChatLive) channel.

  Converts ChatLive form params to `%Incoming{}` and delivers `%Outgoing{}`
  back to the originating LiveView session via Phoenix PubSub.

  Each ChatLive session subscribes to `"chat:<session_id>"`. Pipeline status
  updates are delivered through channels `:upsert_message` and emitted here;
  final results are delivered here via `send_reply/2`.
  """

  @behaviour Zaq.Channels.Bridge
  @behaviour Zaq.Channels.CommunicationBridge

  alias Zaq.Engine.Messages.{Incoming, Outgoing}

  @doc """
  Builds `%Incoming{provider: :web}` from ChatLive form params.

  Expected params keys: `:content`, `:channel_id` (optional, defaults to `"bo"`),
  `:session_id`, `:request_id`.
  """
  @spec to_internal(map(), map()) :: Incoming.t()
  @impl true
  def to_internal(params, _connection_details \\ %{}) do
    Incoming.new(%{
      content: params[:content],
      channel_id: params[:channel_id] || "bo",
      message_id: params[:request_id],
      provider: :web,
      metadata: Map.take(params, [:session_id, :request_id, :user_content])
    })
  end

  @doc """
  Broadcasts `%Outgoing{}` to the originating ChatLive session via PubSub.

  The topic `"chat:<session_id>"` is derived from `outgoing.metadata[:session_id]`.
  The message format is `{:pipeline_result, request_id, outgoing, user_content}`
  to maintain compatibility with the ChatLive handler.
  """
  @spec send_reply(Outgoing.t(), map()) :: :ok | {:error, term()}
  @impl true
  def send_reply(%Outgoing{} = outgoing, _connection_details) do
    session_id = outgoing.metadata[:session_id]
    request_id = outgoing.metadata[:request_id]
    user_content = outgoing.metadata[:user_content]

    Phoenix.PubSub.broadcast(
      Zaq.PubSub,
      "chat:#{session_id}",
      {:pipeline_result, request_id, outgoing, user_content}
    )
  end

  @impl true
  def upsert_message(_config, request, _connection_details) when is_map(request) do
    request_id = Map.get(request, :request_id)
    session_id = Map.get(request, :session_id)
    message = Map.get(request, :body)

    if present?(request_id) and present?(session_id) and present?(message) do
      stage = status_stage(Map.get(request, :intent_meta))

      Phoenix.PubSub.broadcast(
        Zaq.PubSub,
        "chat:#{session_id}",
        {:status_update, request_id, stage, message}
      )

      message_id = Map.get(request, :message_id) || request_id
      action = if present?(Map.get(request, :message_id)), do: :updated, else: :created

      {:ok,
       %{action: action, message_id: message_id, update_intent: Map.get(request, :update_intent)}}
    else
      {:ok, %{action: :noop, message_id: nil, update_intent: Map.get(request, :update_intent)}}
    end
  end

  defp status_stage(%{} = intent_meta) do
    case Map.get(intent_meta, :stage) || Map.get(intent_meta, "stage") do
      stage when is_atom(stage) -> stage
      _ -> :answering
    end
  end

  defp status_stage(_), do: :answering

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value), do: not is_nil(value)
end
