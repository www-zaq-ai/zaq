defmodule Zaq.ConnectorConfig.Settings do
  @moduledoc "Shared write-time provider defaults, enable restrictions, settings merging and stored connector projections."

  @doc "Returns the enable restriction shared by Engine authorization and BO presentation."
  @spec enable_disabled_reason(map(), map() | nil) :: String.t() | nil
  def enable_disabled_reason(%{provider: provider, enabled: false}, user)
      when provider in [:whatsapp, "whatsapp"] do
    unless match?(%{role: %{name: "super_admin"}}, user),
      do: "Only super admins can enable a WhatsApp account."
  end

  def enable_disabled_reason(_, _), do: nil

  @doc "Identifies saved credential bindings whose startup must be excluded during cleanup."
  @spec saved_binding?(term()) :: boolean()
  def saved_binding?(%{settings: settings}) when is_map(settings),
    do: is_integer(settings["credential_document_id"] || settings[:credential_document_id])

  def saved_binding?(_), do: false

  @doc "Returns initial provider settings; explicit saved settings take precedence."
  @spec defaults(atom() | String.t() | nil) :: map()
  def defaults(provider) when provider in [:whatsapp, "whatsapp"] do
    %{
      "jido_chat" => %{
        "room_reply_policy" => "mention_required",
        "ingress" => %{"sync_history" => false, "sync_full_history" => false}
      }
    }
  end

  def defaults(_provider), do: %{}

  @doc "Merges nested maps; explicit scalar, list and null values replace previous values."
  @spec merge(term(), term()) :: term()
  def merge(previous, supplied) when is_map(previous) and is_map(supplied),
    do: Map.merge(previous, supplied, fn _key, old, new -> merge(old, new) end)

  def merge(_previous, supplied), do: supplied

  @doc "Retains saved options covered by provider defaults during partial settings edits."
  @spec preserve(map(), term()) :: term()
  def preserve(config, supplied) do
    retained = configured_values(config.settings, defaults(config.provider))
    merge(retained, supplied)
  end

  defp configured_values(saved, defaults) when is_map(saved) and is_map(defaults) do
    Enum.reduce(defaults, %{}, fn {key, template}, acc ->
      case Map.fetch(saved, key) do
        {:ok, value} -> Map.put(acc, key, configured_values(value, template))
        :error -> acc
      end
    end)
  end

  defp configured_values(saved, _defaults), do: saved

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

  @doc "Returns connector reply policy; malformed stored values conservatively require a mention."
  @spec jido_chat_room_reply_policy(map()) :: :default | :mention_required
  def jido_chat_room_reply_policy(config) do
    with settings when is_map(settings) <- Map.get(config, :settings, %{}),
         chat when is_map(chat) <- Map.get(settings, "jido_chat", %{}) do
      case Map.get(chat, "room_reply_policy", "default") do
        "default" -> :default
        _ -> :mention_required
      end
    else
      _ -> :mention_required
    end
  end

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
