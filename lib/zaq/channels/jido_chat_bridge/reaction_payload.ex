defmodule Zaq.Channels.JidoChatBridge.ReactionPayload do
  @moduledoc """
  Normalizes raw listener reaction payloads into `Jido.Chat.ReactionEvent` structs.

  Listener sinks deliver reactions in provider-specific shapes: Discord's gateway
  worker sends a `%Jido.Chat.EventEnvelope{}` struct, other transports send plain
  maps with atom or string keys. This module collapses all of them into the single
  normalized struct that `JidoChatBridge.handle_reaction_event/2` consumes, so the
  in-process `Jido.Chat.on_reaction/2` handler and the listener sink path feed it
  identical data.

  Normalization is total: an unusable payload returns `:ignored` rather than
  raising, because it runs inside the bridge state process.
  """

  alias Jido.Chat.EventEnvelope
  alias Jido.Chat.ID
  alias Jido.Chat.ReactionEvent

  require Logger

  @doc """
  Returns `:reaction` when `payload` is a reaction event, `:message` otherwise.

  Struct payloads are matched directly — `%EventEnvelope{}` does not implement
  `Access`, so key lookup on it would raise.
  """
  @spec event_type(term()) :: :reaction | :message
  def event_type(%EventEnvelope{event_type: event_type}), do: classify(event_type)
  def event_type(%_{}), do: :message

  def event_type(payload) when is_map(payload),
    do: payload |> get_in_payload([:event_type, "event_type"]) |> classify()

  def event_type(_payload), do: :message

  @doc """
  Builds a normalized reaction event from a listener payload.

  Returns `:ignored` when the payload carries no usable emoji or cannot be
  normalized — both are expected for reactions ZAQ does not act on.
  """
  @spec to_reaction_event(term(), atom(), module()) :: {:ok, ReactionEvent.t()} | :ignored
  def to_reaction_event(payload, adapter_name, adapter) do
    attrs = reaction_attrs(payload)

    case emoji_name(get_in_payload(attrs, [:emoji, "emoji"])) do
      emoji when is_binary(emoji) and emoji != "" ->
        build(attrs, emoji, adapter_name, adapter)

      _ ->
        :ignored
    end
  end

  defp build(attrs, emoji, adapter_name, adapter) do
    channel_id = stringify(get_in_payload(attrs, [:channel_id, "channel_id"]))
    thread_id = stringify(get_in_payload(attrs, [:thread_id, "thread_id"]))

    {:ok,
     ReactionEvent.new(%{
       id: ID.generate!(),
       adapter: adapter,
       adapter_name: adapter_name,
       thread_id: thread_id,
       channel_id: channel_id,
       message_id: stringify(get_in_payload(attrs, [:message_id, "message_id"])),
       emoji: emoji,
       added: added?(get_in_payload(attrs, [:added, "added"])),
       user: user_attrs(get_in_payload(attrs, [:user, "user"])),
       thread: thread_attrs(attrs, thread_id, channel_id, adapter_name, adapter),
       raw: map_or_empty(get_in_payload(attrs, [:raw, "raw"])),
       metadata: map_or_empty(get_in_payload(attrs, [:metadata, "metadata"]))
     })}
  rescue
    error ->
      Logger.warning(
        "[JidoChatBridge] Dropping unnormalizable reaction payload: #{Exception.message(error)}"
      )

      :ignored
  end

  # Envelope-level ids are authoritative; the nested payload carries the rest.
  defp reaction_attrs(%EventEnvelope{} = envelope) do
    envelope.payload
    |> map_or_empty()
    |> put_new_present(:thread_id, envelope.thread_id)
    |> put_new_present(:channel_id, envelope.channel_id)
    |> put_new_present(:message_id, envelope.message_id)
    |> put_new_present(:adapter_name, envelope.adapter_name)
  end

  defp reaction_attrs(payload) when is_map(payload), do: payload
  defp reaction_attrs(_payload), do: %{}

  defp thread_attrs(attrs, thread_id, channel_id, adapter_name, adapter) do
    case get_in_payload(attrs, [:thread, "thread"]) do
      %{__struct__: _} = thread ->
        thread

      _ ->
        room_id = channel_id || thread_id

        if is_binary(thread_id) and is_binary(room_id) do
          %{
            id: thread_id,
            adapter: adapter,
            adapter_name: adapter_name,
            external_room_id: room_id,
            external_thread_id: nil,
            channel_id: channel_id || thread_id,
            metadata: %{}
          }
        end
    end
  end

  defp user_attrs(%{__struct__: _} = user), do: user

  # `Jido.Chat.Author` requires `user_name`, which Discord's gateway payload omits;
  # falling back to the id keeps those reactions from being dropped wholesale.
  defp user_attrs(user) when is_map(user) do
    case stringify(get_in_payload(user, [:user_id, "user_id"])) do
      nil ->
        nil

      user_id ->
        %{
          user_id: user_id,
          user_name: stringify(get_in_payload(user, [:user_name, "user_name"])) || user_id,
          full_name: stringify(get_in_payload(user, [:full_name, "full_name"])),
          is_bot: get_in_payload(user, [:is_bot, "is_bot"]) == true,
          metadata: map_or_empty(get_in_payload(user, [:metadata, "metadata"]))
        }
    end
  end

  defp user_attrs(_user), do: nil

  # Providers send either a bare emoji/short name or a `%{name: ...}` map.
  defp emoji_name(emoji) when is_binary(emoji), do: emoji

  defp emoji_name(emoji) when is_map(emoji),
    do: emoji |> get_in_payload([:name, "name"]) |> emoji_name()

  defp emoji_name(_emoji), do: nil

  defp added?(true), do: true
  defp added?("true"), do: true
  defp added?(false), do: false
  defp added?("false"), do: false
  defp added?(nil), do: true
  defp added?(_other), do: false

  defp classify(:reaction), do: :reaction
  defp classify("reaction"), do: :reaction
  defp classify(_event_type), do: :message

  # Fetch-based rather than `find_value/2` so a legitimate `false` is not skipped.
  defp get_in_payload(map, keys) when is_map(map) do
    Enum.reduce_while(keys, nil, fn key, acc ->
      case Map.fetch(map, key) do
        {:ok, nil} -> {:cont, acc}
        {:ok, value} -> {:halt, value}
        :error -> {:cont, acc}
      end
    end)
  end

  defp get_in_payload(_map, _keys), do: nil

  defp put_new_present(map, _key, nil), do: map
  defp put_new_present(map, key, value), do: Map.put_new(map, key, value)

  defp map_or_empty(%{__struct__: _}), do: %{}
  defp map_or_empty(map) when is_map(map), do: map
  defp map_or_empty(_other), do: %{}

  defp stringify(nil), do: nil
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value), do: to_string(value)
end
