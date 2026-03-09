defmodule Zaq.Channels.Mattermost.API do
  @moduledoc """
  HTTP client for Mattermost REST API using HTTPoison.
  """

  alias Zaq.Channels.ChannelConfig

  @posts_path "/api/v4/posts"
  @typing_delay 1000

  def send_message(channel_id, message) do
    send_typing(channel_id)
    Process.sleep(@typing_delay)

    with %ChannelConfig{} = config <- ChannelConfig.get_by_provider("mattermost") do
      url = config.url <> @posts_path

      body =
        Jason.encode!(%{
          channel_id: channel_id,
          message: message
        })

      headers = [
        {"authorization", "Bearer #{config.token}"},
        {"content-type", "application/json"}
      ]

      case HTTPoison.post(url, body, headers) do
        {:ok, %HTTPoison.Response{status_code: 201, body: resp_body}} ->
          {:ok, Jason.decode!(resp_body)}

        {:ok, %HTTPoison.Response{status_code: status, body: resp_body}} ->
          {:error, %{status: status, body: resp_body}}

        {:error, %HTTPoison.Error{reason: reason}} ->
          {:error, reason}
      end
    else
      nil -> {:error, :mattermost_not_configured}
    end
  end

  def send_typing(channel_id, parent_id \\ "") do
    payload =
      Jason.encode!(%{
        action: "user_typing",
        seq: System.unique_integer([:positive]),
        data: %{channel_id: channel_id, parent_id: parent_id}
      })

    Fresh.send(Zaq.Channels.Mattermost.Client, {:text, payload})
  end

  def clear_channel(channel_id) do
    with %ChannelConfig{} = config <- ChannelConfig.get_by_provider("mattermost") do
      headers = [{"authorization", "Bearer #{config.token}"}]

      case list_channel_posts(config.url, channel_id, headers) do
        {:ok, post_ids} ->
          Enum.each(post_ids, fn post_id ->
            delete_post(config.url, post_id, headers)
            Process.sleep(100)
          end)

          :ok

        {:error, reason} ->
          {:error, reason}
      end
    else
      nil -> {:error, :mattermost_not_configured}
    end
  end

  @doc """
  Sends a message using an explicit config (for testing and direct calls).
  """
  def send_message(config, channel_id, message) do
    url = config.url <> @posts_path

    body =
      Jason.encode!(%{
        channel_id: channel_id,
        message: message
      })

    headers = [
      {"authorization", "Bearer #{config.token}"},
      {"content-type", "application/json"}
    ]

    case HTTPoison.post(url, body, headers) do
      {:ok, %HTTPoison.Response{status_code: 201, body: resp_body}} ->
        {:ok, Jason.decode!(resp_body)}

      {:ok, %HTTPoison.Response{status_code: status, body: resp_body}} ->
        {:error, %{status: status, body: resp_body}}

      {:error, %HTTPoison.Error{reason: reason}} ->
        {:error, reason}
    end
  end

  defp list_channel_posts(base_url, channel_id, headers) do
    url = base_url <> "/api/v4/channels/#{channel_id}/posts"

    case HTTPoison.get(url, headers) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        {:ok, Jason.decode!(body)["order"]}

      {:ok, %HTTPoison.Response{status_code: status, body: body}} ->
        {:error, %{status: status, body: body}}

      {:error, %HTTPoison.Error{reason: reason}} ->
        {:error, reason}
    end
  end

  defp delete_post(base_url, post_id, headers) do
    url = base_url <> "/api/v4/posts/#{post_id}"

    case HTTPoison.delete(url, headers) do
      {:ok, %HTTPoison.Response{status_code: 200}} ->
        :ok

      error ->
        require Logger
        Logger.warning("Failed to delete post #{post_id}: #{inspect(error)}")
    end
  end
end
