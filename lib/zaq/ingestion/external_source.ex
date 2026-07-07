defmodule Zaq.Ingestion.ExternalSource do
  @moduledoc """
  Stable source identifiers for external data-source records.
  """

  alias Zaq.Contracts.Record

  @prefix "data_source"
  @sidecar_root ".external-sidecars"

  @spec external?(Record.t()) :: boolean()
  def external?(%Record{} = record) do
    provider = provider(record)

    is_binary(provider) and provider not in ["", "local", "zaq_local"] and
      not is_nil(config_id(record))
  end

  @spec provider(Record.t()) :: String.t() | nil
  def provider(%Record{} = record), do: attr(record, "provider") || attr(record, :provider)

  @spec config_id(Record.t()) :: String.t() | nil
  def config_id(%Record{} = record) do
    case attr(record, "config_id") || attr(record, :config_id) do
      nil -> nil
      value -> to_string(value)
    end
  end

  @spec file_id(Record.t()) :: String.t()
  def file_id(%Record{id: id} = record),
    do: to_string(attr(record, "provider_record_id") || attr(record, :provider_record_id) || id)

  @spec source(Record.t()) :: String.t()
  def source(%Record{} = record) do
    Enum.join([@prefix, provider(record), config_id(record), file_id(record)], "/")
  end

  @spec sidecar_source(Record.t()) :: String.t()
  def sidecar_source(%Record{} = record), do: source(record) <> ".md"

  @spec sidecar_relative_path(Record.t(), String.t()) :: String.t()
  def sidecar_relative_path(%Record{} = record, ext \\ ".md") do
    Path.join([
      @sidecar_root,
      safe_segment(provider(record)),
      safe_segment(config_id(record)),
      safe_segment(file_id(record)) <> ext
    ])
  end

  @spec metadata(Record.t()) :: map()
  def metadata(%Record{} = record) do
    %{
      "provider" => provider(record),
      "provider_config_id" => config_id(record),
      "provider_file_id" => file_id(record),
      "provider_url" => record.url,
      "provider_mime_type" => record.mime_type,
      "provider_name" => record.name
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
    |> Map.new()
  end

  @spec sidecar_metadata(Record.t(), String.t()) :: map()
  def sidecar_metadata(%Record{} = record, sidecar_relative_path) do
    record
    |> metadata()
    |> Map.put("sidecar_file_path", sidecar_relative_path)
  end

  defp attr(%Record{attributes: attrs}, key) when is_map(attrs), do: Map.get(attrs, key)
  defp attr(%Record{}, _key), do: nil

  defp safe_segment(value) do
    raw = to_string(value)
    sanitized = String.replace(raw, ~r/[^A-Za-z0-9._-]/, "_")
    hash = :crypto.hash(:sha256, raw) |> Base.url_encode64(padding: false) |> binary_part(0, 8)

    if sanitized == "", do: hash, else: sanitized <> "-" <> hash
  end
end
