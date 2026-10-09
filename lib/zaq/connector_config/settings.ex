defmodule Zaq.ConnectorConfig.Settings do
  @moduledoc "Pure settings projections over connector maps, shared across service roles."

  @doc "Returns a stored nested settings map, or an empty map for malformed input."
  def nested(%{settings: settings}, key) when is_map(settings) do
    case Map.get(settings, key, %{}) do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  def nested(_config, _key), do: %{}

  def jido_chat_settings(config), do: nested(config, "jido_chat")

  def jido_chat_setting(config, key, default \\ nil) when is_binary(key),
    do: Map.get(jido_chat_settings(config), key, default)

  def jido_chat_bot_name(config), do: jido_chat_setting(config, "bot_name")
  def jido_chat_bot_user_id(config), do: jido_chat_setting(config, "bot_user_id")
  def imap_settings(config), do: nested(config, "imap")

  def imap_selected_mailboxes(config) do
    config
    |> imap_settings()
    |> Map.get("selected_mailboxes", [])
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end
end
