defmodule Zaq.Channels.JidoChatBridge.Incoming do
  @moduledoc """
  Normalization integrations for the installed Jido chat adapters.

  Selection follows the existing provider registration, with no consumer-specific
  configuration. Integrations interpret transport facts only; Engine owns history.
  """

  alias Zaq.Channels.JidoChatBridge.Incoming.{Discord, Mattermost, Telegram}

  @integrations %{
    "discord" => Discord,
    "mattermost" => Mattermost,
    "telegram" => Telegram
  }

  @doc "Resolves the local normalization integration for an installed adapter."
  def integration(provider), do: Map.get(@integrations, to_string(provider))

  @doc "Normalizes verified transport facts, preserving unknown unsupported inputs."
  def normalize(incoming, provider, adapter) do
    case integration(provider) do
      nil ->
        %{}

      module ->
        incoming = enrich(incoming, module, adapter)

        case module.normalize(incoming.channel_meta, incoming.raw || %{}, incoming.timestamp) do
          {:ok, facts} -> facts
          {:error, _} -> %{}
        end
    end
  end

  defp enrich(incoming, module, adapter) do
    if module && Code.ensure_loaded?(module) && function_exported?(module, :enrich, 2),
      do: module.enrich(incoming, adapter),
      else: incoming
  end

  @doc "Returns the adapter's external message identifier namespace."
  def source_scope(provider, room) do
    case integration(provider) do
      nil -> nil
      module -> module.source_scope(room)
    end
  end
end
