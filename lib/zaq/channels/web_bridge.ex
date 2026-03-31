defmodule Zaq.Channels.WebBridge do
  @moduledoc """
  Bridge for the web (ChatLive) channel.

  Converts ChatLive form params to `%Incoming{}` and delivers `%Outgoing{}`
  back to the originating LiveView session via Phoenix PubSub.

  Each ChatLive session subscribes to `"chat:<session_id>"`. Status updates
  and final results are both broadcast on that topic so the LiveView can
  update the UI without direct process sends.
  """

  alias Zaq.Engine.Messages.{Incoming, Outgoing}

  @doc """
  Builds `%Incoming{provider: :web}` from ChatLive form params.

  Expected params keys: `:content`, `:channel_id` (optional, defaults to `"bo"`),
  `:session_id`, `:request_id`.
  """
  @spec to_internal(map(), map()) :: Incoming.t()
  def to_internal(params, _connection_details \\ %{}) do
    %Incoming{
      content: params[:content],
      channel_id: params[:channel_id] || "bo",
      provider: :web,
      metadata: Map.take(params, [:session_id, :request_id, :user_content])
    }
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

  @doc """
  Returns an `:on_status` callback for `Pipeline.run/2` opts.

  The callback broadcasts `{:status_update, request_id, stage, message}` to the
  session PubSub topic, which the ChatLive `handle_info` already handles.
  """
  @spec on_status_callback(String.t(), String.t()) :: (atom(), String.t() -> :ok)
  def on_status_callback(session_id, request_id) do
    fn stage, message ->
      Phoenix.PubSub.broadcast(
        Zaq.PubSub,
        "chat:#{session_id}",
        {:status_update, request_id, stage, message}
      )

      :ok
    end
  end
end
