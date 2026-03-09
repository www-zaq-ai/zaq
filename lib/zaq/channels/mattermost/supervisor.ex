defmodule Zaq.Channels.Mattermost.Supervisor do
  @moduledoc """
  Supervisor for Mattermost channel processes.
  Starts the WebSocket client and the shared pending questions tracker.
  """
  use Supervisor

  alias Zaq.Channels.ChannelConfig

  def start_link(_opts) do
    Supervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_args) do
    case ChannelConfig.get_by_provider("mattermost") do
      %ChannelConfig{} = config ->
        children = [
          Zaq.Channels.PendingQuestions,
          {Zaq.Channels.Mattermost.Client,
           uri: build_ws_uri(config),
           state: %{token: config.token},
           opts: [
             headers: [{"authorization", "Bearer #{config.token}"}],
             name: {:local, Zaq.Channels.Mattermost.Client}
           ]}
        ]

        Supervisor.init(children, strategy: :one_for_one)

      nil ->
        Supervisor.init([], strategy: :one_for_one)
    end
  end

  defp build_ws_uri(%{url: url}) do
    url
    |> String.replace_leading("https://", "wss://")
    |> String.replace_leading("http://", "ws://")
    |> Kernel.<>("/api/v4/websocket")
  end
end
