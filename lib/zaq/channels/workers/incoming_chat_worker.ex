defmodule Zaq.Channels.Workers.IncomingChatWorker do
  @moduledoc """
  Oban worker for processing incoming webhook payloads from jido_chat adapters.

  Only handles the `:webhook` transport path — WebSocket messages are handled
  inline by `JidoChatBridge.from_listener/3`. Calls `Adapter.transform_incoming/2`
  at dequeue time, keeping struct construction out of the serialization path.

  ## Queue

  Runs on the `:channels` queue.
  """

  use Oban.Worker, queue: :channels, max_attempts: 3

  alias Zaq.Channels.{ChannelConfig, JidoChatBridge}

  @doc """
  Enqueues a webhook payload for async processing. Called by `JidoChatBridge.from_listener/3`
  when transport is `:webhook`.
  """
  def enqueue(config, payload, sink_opts) when is_map(payload) do
    %{
      "payload" => payload,
      "adapter_name" => config.provider,
      "bot_user_id" => config.bot_user_id,
      "transport" => to_string(sink_opts[:transport] || "unknown"),
      "config" => %{"url" => config.url, "token" => config.token}
    }
    |> new()
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{
          "payload" => payload,
          "adapter_name" => adapter_name,
          "transport" => transport,
          "config" => config_data
        }
      }) do
    adapter = ChannelConfig.resolve_adapter(adapter_name)
    config = %{url: config_data["url"], token: config_data["token"]}
    JidoChatBridge.transform_and_handle(config, adapter, payload, safe_to_atom(transport))
  end

  defp safe_to_atom(v) when is_atom(v), do: v

  defp safe_to_atom(v) when is_binary(v) do
    String.to_existing_atom(v)
  rescue
    ArgumentError -> v
  end
end
