defmodule Zaq.Ingestion.ExternalSource do
  @moduledoc """
  Stable source identifiers for external data-source records.
  """

  alias Zaq.Contracts.Record

  @prefix "data_source"

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

  @spec metadata(Record.t()) :: map()
  def metadata(%Record{} = record) do
    %{
      "provider" => provider(record),
      "provider_config_id" => config_id(record),
      "provider_file_id" => file_id(record),
      "provider_parent_id" => record.parent_id,
      "provider_parent_ids" => record.parent_ids || [],
      "provider_url" => record.url,
      "provider_mime_type" => record.mime_type,
      "provider_name" => record.name,
      "materialization_handle" => record.materialization_handle
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value in ["", []] end)
    |> Map.new()
  end

  defp attr(%Record{attributes: attrs}, key) when is_map(attrs), do: Map.get(attrs, key)
  defp attr(%Record{}, _key), do: nil
end
