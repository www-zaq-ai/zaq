defmodule Zaq.Channels.Mattermost.Client do
  @moduledoc """
  WebSocket client for Mattermost using Fresh.
  Connects to /api/v4/websocket and handles real-time events.
  """

  use Fresh

  require Logger
  alias Zaq.Channels.ChannelConfig
  alias Zaq.Channels.Mattermost.EventParser
  alias Zaq.Channels.PendingQuestions

  @behaviour Zaq.Channels.Channel

  # --- Channel behaviour ---

  def connect do
    case ChannelConfig.get_by_provider("mattermost") do
      %ChannelConfig{} = config ->
        connect(config)

      nil ->
        {:error, :mattermost_not_configured}
    end
  end

  @impl Zaq.Channels.Channel
  def connect(config) do
    uri = build_ws_uri(config)
    state = %{token: config.token}
    opts = [headers: [{"authorization", "Bearer #{config.token}"}]]

    start_link(uri: uri, state: state, opts: opts)
  end

  @impl Zaq.Channels.Channel
  def disconnect(pid) do
    Fresh.close(pid, 1000, "Normal Closure")
  end

  @impl Zaq.Channels.Channel
  def send_message(_pid, channel_id, message) do
    Logger.info("Sending message to channel #{channel_id}: #{message}")
    :ok
  end

  @impl Zaq.Channels.Channel
  def handle_event(event) do
    Logger.info("Received event: #{inspect(event)}")
    :ok
  end

  @impl Zaq.Channels.Channel
  def forward_to_engine(event) do
    Logger.info("Forwarding to engine: #{inspect(event)}")
    :ok
  end

  # --- Fresh callbacks ---

  @impl Fresh
  def handle_connect(_status, _headers, state) do
    Logger.info("Connected to Mattermost WebSocket")
    {:ok, state}
  end

  @impl Fresh
  def handle_in({:text, raw}, state) do
    case Jason.decode(raw) do
      {:ok, %{"event" => event_type} = event} ->
        handle_mm_event(event_type, event, state)

      {:ok, other} ->
        Logger.debug("Unhandled WS message: #{inspect(other)}")
        {:ok, state}

      {:error, reason} ->
        Logger.warning("Failed to decode WS message: #{inspect(reason)}")
        {:ok, state}
    end
  end

  @impl Fresh
  def handle_disconnect(_code, _reason, _state) do
    Logger.warning("Disconnected from Mattermost, reconnecting...")
    :reconnect
  end

  # --- Private ---

  defp handle_mm_event("posted", event, state) do
    case EventParser.parse("posted", event) do
      {:ok, %{sender_name: "@zaq"} = _post} ->
        {:ok, state}

      {:ok, post} ->
        case PendingQuestions.check_reply(post) do
          {:answered, answer, callback} ->
            Logger.info("Answer received: #{answer}")
            callback.(answer)
            {:ok, state}

          :ignore ->
            Logger.info("Message from #{post.sender_name}: #{post.message}")
            forward_to_engine(post)
            {:ok, state}
        end

      {:error, reason} ->
        Logger.warning("Failed to parse posted event: #{inspect(reason)}")
        {:ok, state}
    end
  end

  defp handle_mm_event(event_type, _event, state) do
    Logger.debug("Mattermost event: #{event_type}")
    {:ok, state}
  end

  defp build_ws_uri(%{url: url}) do
    url
    |> String.replace_leading("https://", "wss://")
    |> String.replace_leading("http://", "ws://")
    |> Kernel.<>("/api/v4/websocket")
  end
end
