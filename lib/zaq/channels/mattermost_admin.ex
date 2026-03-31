defmodule Zaq.Channels.MattermostAdmin do
  @moduledoc """
  Admin operations for the Mattermost channel configuration UI.

  Provides browse, send, and management functions used by `ChannelsLive`.
  Backed by the `jido_chat_mattermost` transport layer.
  Not intended for bot ingress/egress — use `Jido.Chat.Mattermost.Adapter` for that.
  """

  alias Jido.Chat.Mattermost.Transport.ReqClient
  alias Zaq.Channels.ChannelConfig

  # ---------------------------------------------------------------------------
  # Send
  # ---------------------------------------------------------------------------

  @doc "Sends a message to a channel. Loads config from DB."
  def send_message(channel_id, message) do
    with {:ok, opts} <- config_opts() do
      ReqClient.send_message(channel_id, message, opts)
    end
  end

  # ---------------------------------------------------------------------------
  # Channel discovery
  # ---------------------------------------------------------------------------

  @doc "Fetches the bot's Mattermost user ID by calling /api/v4/users/me."
  def fetch_bot_user_id(url, token) do
    case Req.get("#{url}/api/v4/users/me",
           headers: [{"Authorization", "Bearer #{token}"}]
         ) do
      {:ok, %{status: 200, body: %{"id" => id}}} -> {:ok, id}
      {:ok, %{status: status}} -> {:error, "HTTP #{status}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  @doc "Lists all teams the bot belongs to."
  def list_teams(config) do
    case ReqClient.list_teams(to_opts(config)) do
      {:ok, teams} -> {:ok, Enum.map(teams, &atomize/1)}
      error -> error
    end
  end

  @doc "Lists public channels for a given team."
  def list_public_channels(config, team_id) do
    case ReqClient.list_public_channels(team_id, to_opts(config)) do
      {:ok, channels} -> {:ok, Enum.map(channels, &atomize/1)}
      error -> error
    end
  end

  # ---------------------------------------------------------------------------
  # Destructive admin
  # ---------------------------------------------------------------------------

  @doc """
  Deletes all posts in a channel. Destructive — use with care.
  Fetches all posts then deletes them individually.
  """
  def clear_channel(channel_id) do
    with {:ok, opts} <- config_opts(),
         {:ok, posts_map} <- ReqClient.fetch_posts(channel_id, opts) do
      post_ids =
        posts_map
        |> Map.get("posts", %{})
        |> Map.keys()

      Enum.each(post_ids, fn post_id ->
        ReqClient.delete_message(channel_id, post_id, opts)
      end)

      {:ok, length(post_ids)}
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp config_opts do
    case ChannelConfig.get_by_provider("mattermost") do
      nil -> {:error, :mattermost_not_configured}
      config -> {:ok, to_opts(config)}
    end
  end

  defp to_opts(config), do: [url: config.url, token: config.token]

  defp atomize(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {String.to_atom(k), v} end)
  end
end
