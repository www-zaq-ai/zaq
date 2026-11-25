defmodule Zaq.Channels.JidoChatBridge.AdapterOptions do
  @moduledoc """
  Builds the credential options `Zaq.Channels.JidoChatBridge` passes to jido_chat
  adapters, so per-provider credential shapes live in one place.

  Mattermost, Discord and Telegram use the default `[url: url, token: token]`.

  Teams uses `[app_id: id, app_password: secret, app_tenant_id: tenant]`.
  """

  alias Zaq.ConnectorConfig.Settings

  @doc "Returns the adapter credential options for `provider` from a connection map or config."
  @spec build(atom() | String.t() | nil, map()) :: keyword()
  def build(provider, connection) when provider in [:teams, "teams"] and is_map(connection) do
    [
      app_id: Settings.jido_chat_setting(connection, "app_id"),
      app_password: value(connection, :token),
      app_tenant_id: Settings.jido_chat_setting(connection, "tenant_id")
    ]
  end

  def build(_provider, connection) when is_map(connection) do
    [url: value(connection, :url), token: value(connection, :token)]
  end

  defp value(connection, key),
    do: Map.get(connection, key) || Map.get(connection, Atom.to_string(key))
end
