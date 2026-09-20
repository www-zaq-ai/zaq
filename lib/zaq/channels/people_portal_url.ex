defmodule Zaq.Channels.PeoplePortalUrl do
  @moduledoc """
  Builds fixed People portal destinations from the configured global base URL.

  Channels reads the persisted base URL through Engine's existing System
  configuration action. URL validation and fixed-path composition remain local and
  never perform persistence access.

  The global base URL may include a deployment path prefix. Unsafe or ambiguous
  values return `nil`; callers must then provide configuration guidance rather
  than emitting a broken link.
  """

  @credentials_path "/people/credentials"

  @spec credentials(keyword()) :: String.t() | nil
  def credentials(opts \\ []) do
    event =
      Zaq.Event.new(%{}, :engine, opts: [action: :system_config_get_global_base_url])

    node_router = Keyword.get(opts, :node_router_module, Zaq.NodeRouter)

    case node_router.dispatch(event).response do
      base_url when is_binary(base_url) -> build(base_url)
      _missing_or_error -> nil
    end
  end

  @doc "Builds the fixed People credentials destination from a validated base URL."
  @spec build(term()) :: String.t() | nil
  def build(base_url) when is_binary(base_url) do
    base_url = String.trim(base_url)

    with true <- safe_source?(base_url),
         {:ok, uri} <- URI.new(base_url),
         true <- safe_uri?(uri) do
      path = String.trim_trailing(uri.path || "", "/") <> @credentials_path
      URI.to_string(%{uri | path: path})
    else
      _ -> nil
    end
  end

  def build(_base_url), do: nil

  defp safe_source?(value) do
    value != "" and not String.contains?(value, ["\\", "<", ">", "\r", "\n", "\0"])
  end

  defp safe_uri?(%URI{} = uri) do
    uri.scheme in ["http", "https"] and present?(uri.host) and is_nil(uri.userinfo) and
      is_nil(uri.query) and is_nil(uri.fragment) and safe_path?(uri.path)
  end

  defp safe_path?(path) when path in [nil, ""], do: true

  defp safe_path?(path) do
    decoded = URI.decode(path)

    decoded
    |> String.split("/", trim: true)
    |> Enum.all?(&(&1 not in [".", ".."]))
  rescue
    ArgumentError -> false
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
