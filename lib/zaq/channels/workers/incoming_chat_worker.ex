defmodule Zaq.Channels.Workers.IncomingChatWorker do
  @moduledoc """
  Oban worker for processing incoming jido_chat messages (Mattermost, Discord, Telegram, etc.).

  `enqueue/3` is the sink target for any jido_chat adapter listener. It stores
  the raw adapter payload (a plain JSON-safe map) into Oban job args and calls
  `Adapter.transform_incoming/2` in `perform/1` — keeping atom/struct construction
  out of the serialization path.

  ## Queue

  Runs on the `:channels` queue.
  """

  use Oban.Worker, queue: :channels, max_attempts: 3

  alias Zaq.Channels.{ChannelConfig, JidoChatBridge}

  @doc """
  Sink target for `sink_mfa`. Accepts a raw adapter payload map and the channel
  config. The payload must be JSON-serializable (no atoms or structs).

  `sink_opts` may include `transport: "websocket"` to be forwarded as metadata.
  """
  def enqueue(config, payload, sink_opts) when is_map(payload) do
    %{
      "payload" => json_safe(payload),
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
          "bot_user_id" => bot_user_id,
          "transport" => transport,
          "config" => config_data
        }
      }) do
    adapter = ChannelConfig.resolve_adapter(adapter_name)
    adapter_opts = [url: config_data["url"], token: config_data["token"]]

    case call_transform_incoming(adapter, payload, adapter_opts) do
      {:ok, incoming} ->
        if bot_message?(incoming, bot_user_id) do
          :ok
        else
          incoming = %{
            incoming
            | metadata: Map.put(incoming.metadata, :transport, safe_to_atom(transport))
          }

          config = %{url: config_data["url"], token: config_data["token"]}
          JidoChatBridge.handle_from_listener(config, incoming, [])
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp bot_message?(_incoming, nil), do: false

  defp bot_message?(incoming, bot_user_id) do
    incoming.author && to_string(incoming.author.user_id) == to_string(bot_user_id)
  end

  # Some adapters (Discord) have 1-arity transform_incoming; others (Mattermost)
  # have 2-arity with opts. Call whichever is exported.
  defp call_transform_incoming(adapter, payload, adapter_opts) do
    if function_exported?(adapter, :transform_incoming, 2) do
      adapter.transform_incoming(payload, adapter_opts)
    else
      adapter.transform_incoming(payload)
    end
  end

  # Recursively converts payload to JSON-safe values.
  # Tuples (Discord snowflakes, timestamps) become lists.
  # Atom keys become strings. Structs are flattened to maps.
  defp json_safe(map) when is_map(map) and not is_struct(map) do
    Map.new(map, fn {k, v} -> {json_safe_key(k), json_safe(v)} end)
  end

  defp json_safe(list) when is_list(list), do: Enum.map(list, &json_safe/1)
  defp json_safe(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> json_safe()

  defp json_safe(atom) when is_atom(atom) and not is_boolean(atom) and atom != nil,
    do: Atom.to_string(atom)

  defp json_safe(value), do: value

  defp json_safe_key(k) when is_atom(k), do: Atom.to_string(k)
  defp json_safe_key(k), do: to_string(k)

  defp safe_to_atom(v) when is_atom(v), do: v

  defp safe_to_atom(v) when is_binary(v) do
    String.to_existing_atom(v)
  rescue
    ArgumentError -> v
  end
end
