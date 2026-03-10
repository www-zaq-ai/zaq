defmodule Zaq.Channels.Retrieval.Mattermost.API do
  @moduledoc """
  HTTP client for Mattermost REST API using HTTPoison.
  """

  alias Zaq.Channels.ChannelConfig

  @posts_path "/api/v4/posts"
  @typing_delay 1000

  @doc """
  Sends a message to a channel, optionally within a thread.
  Loads config from DB.
  """
  def send_message(channel_id, message, thread_id \\ nil) do
    send_typing(channel_id)
    Process.sleep(@typing_delay)

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

  def clear_channel(channel_id) do
    case ChannelConfig.get_by_provider("mattermost") do
      %ChannelConfig{} = config ->
        headers = [{"authorization", "Bearer #{config.token}"}]
        delete_all_posts(config.url, channel_id, headers)

      nil ->
        {:error, :mattermost_not_configured}
    end
  end

  # --- Private ---

  defp do_send_message(config, channel_id, message, thread_id) do
    url = config.url <> @posts_path

    body =
      %{channel_id: channel_id, message: message}
      |> maybe_put_root_id(thread_id)
      |> Jason.encode!()

    headers = [
      {"authorization", "Bearer #{config.token}"},
      {"content-type", "application/json"}
    ]

    do_post(url, body, headers)
  end

  defp maybe_put_root_id(body, nil), do: body
  defp maybe_put_root_id(body, ""), do: body
  defp maybe_put_root_id(body, thread_id), do: Map.put(body, :root_id, thread_id)

  defp do_post(url, body, headers) do
    case HTTPoison.post(url, body, headers) do
      {:ok, %HTTPoison.Response{status_code: 201, body: resp_body}} ->
        {:ok, Jason.decode!(resp_body)}

      {:ok, %HTTPoison.Response{status_code: status, body: resp_body}} ->
        {:error, %{status: status, body: resp_body}}

      {:error, %HTTPoison.Error{reason: reason}} ->
        {:error, reason}
    end
  end

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
