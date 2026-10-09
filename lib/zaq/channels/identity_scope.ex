defmodule Zaq.Channels.IdentityScope do
  @moduledoc """
  Canonical authority of native communication identities, independent of a bot.
  Provider semantics belong here; consumers compare the resulting opaque key.
  Endpoint-scoped authorities retain deployment paths. Unknown tenant scope stays
  connector-local rather than guessing that opaque IDs are globally unique.
  """

  @spec authority(String.t(), map() | nil) :: String.t()
  def authority(platform, _config) when platform in ["email", "telegram", "discord"],
    do: "global"

  def authority("mattermost", %{url: url} = config) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} = uri
      when scheme in ["http", "https"] and is_binary(host) ->
        %{
          uri
          | host: String.downcase(host),
            userinfo: nil,
            query: nil,
            fragment: nil,
            path: String.trim_trailing(uri.path || "", "/")
        }
        |> URI.to_string()

      _ ->
        connector_authority(config)
    end
  end

  def authority(_platform, config), do: connector_authority(config)

  defp connector_authority(%{id: id}) when is_integer(id), do: "connector:#{id}"
  defp connector_authority(_), do: "unscoped"
end
