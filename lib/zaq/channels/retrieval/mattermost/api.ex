defmodule Zaq.Channels.Retrieval.Mattermost.API do
  @moduledoc """
  HTTP client for Mattermost REST API using Req.
  """

  alias Zaq.Channels.ChannelConfig

  @posts_path "/api/v4/posts"
  @typing_delay 1000

  # ---------------------------------------------------------------------------
  # Send Message
  # ---------------------------------------------------------------------------

  @doc """
  Sends a message to a channel, optionally within a thread.
  Loads config from DB.
  """
  def send_message(channel_id, message, thread_id \\ nil) do
    try do
      send_typing(channel_id)
      Process.sleep(@typing_delay)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end

    case ChannelConfig.get_by_provider("mattermost") do
      %ChannelConfig{} = config ->
        do_send_message(config, channel_id, message, thread_id)

      nil ->
        {:error, :mattermost_not_configured}
    end
  end

  @doc """
  Sends a message using an explicit config (for testing and direct calls).
  """
  def send_message(config, channel_id, message, thread_id) do
    do_send_message(config, channel_id, message, thread_id)
  end

  def send_typing(channel_id, parent_id \\ "") do
    payload =
      Jason.encode!(%{
        action: "user_typing",
        seq: System.unique_integer([:positive]),
        data: %{channel_id: channel_id, parent_id: parent_id}
      })

    Fresh.send(Zaq.Channels.Retrieval.Mattermost, {:text, payload})
  end

  # ---------------------------------------------------------------------------
  # Channel Discovery
  # ---------------------------------------------------------------------------

  @doc """
  Returns the bot's own user ID. Used to filter out self-replies.

  Calls `GET /api/v4/users/me`.
  """
  def get_bot_user(%ChannelConfig{} = config) do
    url = config.url <> "/api/v4/users/me"

    case Req.get(url, headers: auth_headers(config)) do
      {:ok, %Req.Response{status: 200, body: user}} ->
        {:ok, %{id: user["id"], username: user["username"]}}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, %{status: status, body: body}}

      {:error, exception} ->
        {:error, exception.reason}
    end
  end

  @doc """
  Lists teams the bot belongs to.

  Calls `GET /api/v4/users/me/teams`.
  Returns `{:ok, [%{id, display_name, name}]}`.
  """
  def list_teams(%ChannelConfig{} = config) do
    url = config.url <> "/api/v4/users/me/teams"

    case Req.get(url, headers: auth_headers(config)) do
      {:ok, %Req.Response{status: 200, body: teams}} ->
        {:ok,
         Enum.map(teams, fn t ->
           %{id: t["id"], display_name: t["display_name"], name: t["name"]}
         end)}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, %{status: status, body: body}}

      {:error, exception} ->
        {:error, exception.reason}
    end
  end

  @doc """
  Lists public channels for a given team. Supports pagination.

  Calls `GET /api/v4/teams/:team_id/channels?page=0&per_page=100`.
  Returns `{:ok, [%{id, display_name, name, type, header, purpose}]}`.

  Only returns public channels (type "O").
  """
  def list_public_channels(%ChannelConfig{} = config, team_id, opts \\ []) do
    page = Keyword.get(opts, :page, 0)
    per_page = Keyword.get(opts, :per_page, 100)

    url = config.url <> "/api/v4/teams/#{team_id}/channels?page=#{page}&per_page=#{per_page}"

    case Req.get(url, headers: auth_headers(config)) do
      {:ok, %Req.Response{status: 200, body: channels}} ->
        result =
          channels
          |> Enum.filter(fn ch -> ch["type"] == "O" end)
          |> Enum.map(fn ch ->
            %{
              id: ch["id"],
              display_name: ch["display_name"],
              name: ch["name"],
              type: ch["type"],
              header: ch["header"],
              purpose: ch["purpose"]
            }
          end)
          |> Enum.sort_by(& &1.display_name)

        {:ok, result}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, %{status: status, body: body}}

      {:error, exception} ->
        {:error, exception.reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Clear Channel
  # ---------------------------------------------------------------------------

  def clear_channel(channel_id) do
    case ChannelConfig.get_by_provider("mattermost") do
      %ChannelConfig{} = config ->
        headers = auth_headers(config)
        delete_all_posts(config.url, channel_id, headers)

      nil ->
        {:error, :mattermost_not_configured}
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp auth_headers(%ChannelConfig{token: token}) do
    [{"authorization", "Bearer #{token}"}]
  end

  defp do_send_message(config, channel_id, message, thread_id) do
    url = config.url <> @posts_path

    body =
      %{channel_id: channel_id, message: message}
      |> maybe_put_root_id(thread_id)

    case Req.post(url, headers: auth_headers(config), json: body) do
      {:ok, %Req.Response{status: 201, body: resp_body}} ->
        {:ok, resp_body}

      {:ok, %Req.Response{status: status, body: resp_body}} ->
        {:error, %{status: status, body: resp_body}}

      {:error, exception} ->
        {:error, exception.reason}
    end
  end

  defp maybe_put_root_id(body, nil), do: body
  defp maybe_put_root_id(body, ""), do: body
  defp maybe_put_root_id(body, thread_id), do: Map.put(body, :root_id, thread_id)

  defp delete_all_posts(base_url, channel_id, headers) do
    case list_channel_posts(base_url, channel_id, headers) do
      {:ok, post_ids} ->
        Enum.each(post_ids, fn post_id ->
          delete_post(base_url, post_id, headers)
          Process.sleep(100)
        end)

        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp list_channel_posts(base_url, channel_id, headers) do
    url = base_url <> "/api/v4/channels/#{channel_id}/posts"

    case Req.get(url, headers: headers) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body["order"]}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, %{status: status, body: body}}

      {:error, exception} ->
        {:error, exception.reason}
    end
  end

  defp delete_post(base_url, post_id, headers) do
    url = base_url <> "/api/v4/posts/#{post_id}"

    case Req.delete(url, headers: headers) do
      {:ok, %Req.Response{status: 200}} ->
        :ok

      error ->
        require Logger
        Logger.warning("Failed to delete post #{post_id}: #{inspect(error)}")
    end
  end
end
