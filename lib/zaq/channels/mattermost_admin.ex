defmodule Zaq.Channels.MattermostAdmin do
  @moduledoc """
  Admin operations for the Mattermost channel configuration UI.

  Provides browse, send, and management functions used by `ChannelsLive`.
  Backed by the `jido_chat_mattermost` transport layer.
  Not intended for bot ingress/egress — use `Jido.Chat.Mattermost.Adapter` for that.
  """

  alias Jido.Chat.Mattermost.Transport.ReqClient
  alias Zaq.Channels.ChannelConfig

  @membership_page_size 200
  @membership_max_pages 50

  @doc "Reads a root post for bounded BO history context, verifying its exact room and identity."
  def history_root(config, channel_id, message_id) when is_binary(message_id) do
    with true <- Regex.match?(~r/\A[a-zA-Z0-9_-]{1,255}\z/, message_id),
         {:ok,
          %{
            status: 200,
            body:
              %{
                "id" => ^message_id,
                "channel_id" => ^channel_id,
                "root_id" => "",
                "user_id" => author,
                "message" => content
              } = post
          }} <-
           Req.get(config.url <> "/api/v4/posts/" <> message_id,
             headers: [{"Authorization", "Bearer " <> config.token}],
             retry: false,
             receive_timeout: 3_000
           ),
         true <- is_binary(author) and is_binary(content) do
      {:ok,
       %{
         author_id: author,
         author_name: author,
         content: content,
         role:
           if(author == ChannelConfig.jido_chat_bot_user_id(config),
             do: "assistant",
             else: "external"
           ),
         inserted_at: root_timestamp(post["create_at"]),
         attachments: []
       }}
    else
      _ -> {:error, :unavailable}
    end
  end

  def history_root(_, _, _), do: {:error, :unavailable}

  defp root_timestamp(value) when is_integer(value) do
    case DateTime.from_unix(value, :millisecond) do
      {:ok, timestamp} -> timestamp
      _ -> nil
    end
  end

  defp root_timestamp(_), do: nil

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

  @doc "Fetches the authenticated Mattermost account's ID and username."
  def fetch_bot_identity(url, token) do
    case get([url: url, token: token], "/api/v4/users/me", []) do
      {:ok, %{"id" => id, "username" => username}}
      when is_binary(id) and id != "" and is_binary(username) and username != "" ->
        {:ok, %{id: id, username: username}}

      {:ok, _body} ->
        {:error, :invalid_identity}

      {:error, {status, _body}} ->
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  @doc "Fetches only the Mattermost user ID (use fetch_bot_identity/2 for both fields)."
  def fetch_bot_user_id(url, token) do
    with {:ok, %{id: id}} <- fetch_bot_identity(url, token), do: {:ok, id}
  end

  @doc "Lists all teams the bot belongs to."
  def list_teams(config) do
    case ReqClient.list_teams(to_opts(config)) do
      {:ok, teams} -> {:ok, Enum.map(teams, &atomize/1)}
      error -> error
    end
  end

  @doc "Lists channels in a team that the bot can access, including private channels it belongs to."
  def list_accessible_channels(config, team_id) do
    config
    |> to_opts()
    |> get("/api/v4/users/me/teams/#{team_id}/channels", per_page: 200)
    |> case do
      {:ok, channels} -> {:ok, Enum.map(channels, &atomize/1)}
      error -> error
    end
  end

  @doc "Fetches a Mattermost user for BO display labels such as direct-message channel names."
  def fetch_user(config, user_id) do
    config
    |> to_opts()
    |> get("/api/v4/users/#{user_id}", [])
    |> case do
      {:ok, user} when is_map(user) -> {:ok, atomize(user)}
      error -> error
    end
  end

  @doc "Returns a complete channel membership snapshot, or an error without a partial member list."
  def channel_membership_snapshot(config, channel_id, opts \\ [])

  def channel_membership_snapshot(config, channel_id, opts)
      when is_binary(channel_id) and is_list(opts) do
    if Regex.match?(~r/\A[a-z0-9]{26}\z/, channel_id) do
      fetch_page = Keyword.get(opts, :fetch_page, &fetch_membership_page/4)
      collect_members(config, channel_id, fetch_page, 0, MapSet.new())
    else
      {:error, :invalid_channel_id}
    end
  end

  def channel_membership_snapshot(_, _, _), do: {:error, :invalid_channel_id}

  defp collect_members(_config, _channel_id, _fetch_page, @membership_max_pages, _seen),
    do: {:error, :snapshot_too_large}

  defp collect_members(config, channel_id, fetch_page, page, seen) do
    case fetch_page.(config, channel_id, page, @membership_page_size) do
      {:ok, rows} when is_list(rows) and length(rows) <= @membership_page_size ->
        with {:ok, ids} <- member_ids(rows) do
          collected_members(config, channel_id, fetch_page, page, seen, rows, ids)
        end

      {:error, _} = error ->
        error

      _ ->
        {:error, :invalid_membership_page}
    end
  end

  defp collected_members(config, channel_id, fetch_page, page, seen, rows, ids) do
    members = Enum.reduce(ids, seen, &MapSet.put(&2, &1))

    if length(rows) < @membership_page_size do
      {:ok, %{complete: true, member_ids: members |> MapSet.to_list() |> Enum.sort()}}
    else
      collect_members(config, channel_id, fetch_page, page + 1, members)
    end
  end

  defp member_ids(rows) do
    if Enum.all?(rows, fn
         %{"user_id" => id} when is_binary(id) -> id != "" and byte_size(id) <= 255
         _ -> false
       end),
       do: {:ok, Enum.map(rows, & &1["user_id"])},
       else: {:error, :invalid_membership_page}
  end

  defp fetch_membership_page(config, channel_id, page, per_page) do
    config
    |> to_opts()
    |> get("/api/v4/channels/#{channel_id}/members", page: page, per_page: per_page)
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

  defp get(opts, path, params) do
    url = Keyword.fetch!(opts, :url) <> path
    token = Keyword.fetch!(opts, :token)

    case Req.get(url, params: params, headers: [{"Authorization", "Bearer #{token}"}]) do
      {:ok, %{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, {status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp atomize(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {String.to_atom(k), v} end)
  end
end
