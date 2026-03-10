defmodule Zaq.Channels.Retrieval.Mattermost do
  @moduledoc """
  Retrieval channel adapter for Mattermost.

  Connects to Mattermost via WebSocket, listens for incoming messages,
  and forwards user questions to the Engine pipeline.

  Implements `Zaq.Engine.RetrievalChannel`.

  Started dynamically by `Zaq.Engine.RetrievalSupervisor` when a Mattermost
  channel config with `kind: "retrieval"` is present and enabled in the database.
  """

  use Fresh

  require Logger

  alias Zaq.Channels.PendingQuestions
  alias Zaq.Channels.Retrieval.Mattermost.API
  alias Zaq.Channels.Retrieval.Mattermost.EventParser

  @behaviour Zaq.Engine.RetrievalChannel

  # --- RetrievalChannel behaviour ---

  @impl Zaq.Engine.RetrievalChannel
  def connect(%Zaq.Channels.ChannelConfig{} = config) do
    uri = build_ws_uri(config)
    state = %{token: config.token, config: config}

    opts = [
      headers: [{"authorization", "Bearer #{config.token}"}],
      name: {:local, __MODULE__}
    ]

    start_link(uri: uri, state: state, opts: opts)
  end

  @impl Zaq.Engine.RetrievalChannel
  def disconnect(pid) do
    Fresh.close(pid, 1000, "Normal Closure")
  end

  @impl Zaq.Engine.RetrievalChannel
  def send_message(channel_id, message, thread_id) do
    API.send_message(channel_id, message, thread_id)
  end

  @impl Zaq.Engine.RetrievalChannel
  def handle_event(event) do
    Logger.info("[Mattermost] Received event: #{inspect(event)}")
    :ok
  end

  @impl Zaq.Engine.RetrievalChannel
  def forward_to_engine(question) do
    Logger.info("[Mattermost] Forwarding to engine: #{inspect(question)}")
    :ok
  end

  # --- Fresh callbacks ---

  @impl Fresh
  def handle_connect(_status, _headers, state) do
    Logger.info("[Mattermost] Connected to WebSocket")
    {:ok, state}
  end

  @impl Fresh
  def handle_in({:text, raw}, state) do
    case Jason.decode(raw) do
      {:ok, %{"event" => event_type} = event} ->
        handle_mm_event(event_type, event, state)

      {:ok, other} ->
        Logger.debug("[Mattermost] Unhandled WS message: #{inspect(other)}")
        {:ok, state}

      {:error, reason} ->
        Logger.warning("[Mattermost] Failed to decode WS message: #{inspect(reason)}")
        {:ok, state}
    end
  end

  @impl Fresh
  def handle_disconnect(_code, _reason, _state) do
    Logger.warning("[Mattermost] Disconnected, reconnecting...")
    :reconnect
  end

  # --- Private ---

  defp handle_mm_event("posted", event, state) do
    case EventParser.parse("posted", event) do
      {:ok, %{sender_name: "@zaq"}} ->
        {:ok, state}

      {:ok, post} ->
        case PendingQuestions.check_reply(post) do
          {:answered, answer, callback} ->
            Logger.info("[Mattermost] Answer received: #{answer}")
            callback.(answer)
            {:ok, state}

          :ignore ->
            forward_to_engine(%{
              text: post.message,
              channel_id: post.channel_id,
              user_id: post.user_id,
              thread_id: post.root_id,
              metadata: %{
                sender_name: post.sender_name,
                channel_name: post.channel_name,
                channel_type: post.channel_type,
                post_id: post.id,
                create_at: post.create_at
              }
            })

            {:ok, state}
        end

      {:error, reason} ->
        Logger.warning("[Mattermost] Failed to parse posted event: #{inspect(reason)}")
        {:ok, state}

      {:unknown, event_type} ->
        Logger.debug("[Mattermost] Unknown event type: #{event_type}")
        {:ok, state}
    end
  end

  defp handle_mm_event(event_type, _event, state) do
    Logger.debug("[Mattermost] Event: #{event_type}")
    {:ok, state}
  end

  defp build_ws_uri(%{url: url}) do
    url
    |> String.replace_leading("https://", "wss://")
    |> String.replace_leading("http://", "ws://")
    |> Kernel.<>("/api/v4/websocket")
  end
end
