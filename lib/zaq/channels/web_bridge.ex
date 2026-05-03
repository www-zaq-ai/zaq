defmodule Zaq.Channels.WebBridge do
  @moduledoc """
  Bridge for the web (ChatLive) channel.

  Converts ChatLive form params to `%Incoming{}` and delivers `%Outgoing{}`
  back to the originating LiveView session via Phoenix PubSub.

  Each ChatLive session subscribes to `"chat:<session_id>"`. Pipeline status
  updates are broadcast directly by `Zaq.Agent.Status`; final results are
  delivered here via `send_reply/2`.
  """

  @behaviour Zaq.Channels.Bridge

  alias Zaq.Engine.Messages.{Incoming, Outgoing}

  @doc """
  Builds `%Incoming{provider: :web}` from ChatLive form params.

  Expected params keys: `:content`, `:channel_id` (optional, defaults to `"bo"`),
  `:session_id`, `:request_id`.
  """
  @spec to_internal(map(), map()) :: Incoming.t()
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
end
