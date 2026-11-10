defmodule Zaq.Channels.JidoChatBridge.AdapterOptions do
  @moduledoc """
  Builds the credential options `Zaq.Channels.JidoChatBridge` passes to jido_chat
  adapters, so per-provider credential shapes live in one place.

  Mattermost, Discord and Telegram use the default `[url: url, token: token]`.
  """

  @doc "Returns the adapter credential options for `provider` from a connection map or config."
  @spec build(atom() | String.t() | nil, map()) :: keyword()
  def build(_provider, connection) when is_map(connection) do
    settings = value(connection, :settings) || %{}

    [url: value(connection, :url), token: value(connection, :token)]
    |> maybe_put(:transport, value(connection, :transport))
    |> maybe_put(:attachment_failure_policy, value(connection, :attachment_failure_policy))
    |> maybe_put(
      :max_file_size,
      value(connection, :max_file_size) || value(settings, :max_file_size)
    )
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp value(connection, key),
    do: Map.get(connection, key) || Map.get(connection, Atom.to_string(key))
end
