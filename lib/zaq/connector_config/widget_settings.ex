defmodule Zaq.ConnectorConfig.WidgetSettings do
  @moduledoc """
  Pure validation of persisted widget presentation, embedding and authentication settings.

  Stylesheet URLs belong to instance initialization, never connector settings.

  Engine connector persistence and Channels runtime construction share this
  value contract. It does not build runtimes, authenticate senders or enforce
  endpoint access; those responsibilities remain with their existing owners.
  """

  @defaults %{
    "identity_issuer" => "zaq_issuer",
    "identity_audience" => "zaq_audience",
    "same_site" => "None"
  }

  @doc "Defaults for new connectors only; legacy omitted settings retain their runtime policy."
  @spec defaults() :: map()
  def defaults, do: @defaults

  @doc "Validates the settings map without interpreting a browser-supplied widget identity."
  @spec validate(term()) :: :ok | {:error, :invalid_widget_settings}
  def validate(settings) when is_map(settings) do
    valid =
      not Map.has_key?(settings, "widget_id") and not Map.has_key?(settings, :widget_id) and
        valid_name?(Map.get(settings, "display_name")) and
        valid_domains?(Map.get(settings, "allowed_domains", [])) and
        not Map.has_key?(settings, "stylesheet_url") and
        not Map.has_key?(settings, :stylesheet_url) and
        valid_authentication?(settings)

    if valid, do: :ok, else: {:error, :invalid_widget_settings}
  end

  def validate(_settings), do: {:error, :invalid_widget_settings}

  defp valid_authentication?(settings) do
    not Enum.any?([:identity_issuer, :identity_audience, :same_site], &Map.has_key?(settings, &1)) and
      optional_setting?(settings, "identity_issuer", &valid_identifier?/1) and
      optional_setting?(settings, "identity_audience", &valid_identifier?/1) and
      optional_setting?(settings, "same_site", &(&1 in ["None", "Lax", "Strict"]))
  end

  defp optional_setting?(settings, key, validate) do
    case Map.fetch(settings, key) do
      :error -> true
      {:ok, value} -> validate.(value)
    end
  end

  defp valid_identifier?(value) when is_binary(value),
    do: String.valid?(value) and byte_size(value) in 1..255 and String.trim(value) == value

  defp valid_identifier?(_value), do: false

  defp valid_name?(nil), do: true

  defp valid_name?(name) when is_binary(name),
    do: String.trim(name) != "" and byte_size(name) <= 200

  defp valid_name?(_name), do: false

  defp valid_domains?(domains) when is_list(domains),
    do: length(domains) <= 100 and Enum.all?(domains, &valid_origin?/1)

  defp valid_domains?(_domains), do: false

  defp valid_origin?(origin) when is_binary(origin) and byte_size(origin) <= 2_048 do
    uri = URI.parse(origin)

    uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" and
      not String.contains?(uri.host, "*") and is_nil(uri.userinfo) and uri.path in [nil, ""] and
      is_nil(uri.query) and is_nil(uri.fragment)
  end

  defp valid_origin?(_origin), do: false
end
