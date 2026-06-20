defmodule Zaq.Ingestion.RecordSource do
  @moduledoc """
  Resolves canonical records into content sources usable by ingestion.

  Phase 1 supports local volume records by resolving their `attributes` into
  volume-relative paths. Future external data-source phases should extend this
  boundary to fetch/export record content through NodeRouter-routed data-source
  events, without adding provider-specific ingestion logic.
  """

  alias Zaq.Contracts.Record
  alias Zaq.Ingestion.{FileExplorer, VolumeRecords}

  def kind(%Record{kind: kind}), do: normalize_kind(kind)
  def kind(%{"kind" => kind}), do: normalize_kind(kind)
  def kind(%{kind: kind}), do: normalize_kind(kind)
  def kind(_), do: :unknown

  def relative_path(record),
    do: attr(record, "relative_path") || attr(record, :relative_path) || record_path(record)

  def volume(record), do: attr(record, "volume") || attr(record, :volume)

  def resolve_path(record) do
    with volume when is_binary(volume) <- volume(record),
         path when is_binary(path) <- relative_path(record) do
      FileExplorer.resolve_path(volume, path)
    else
      _ -> {:error, :unsupported_record_source}
    end
  end

  def list_children(record) do
    with volume when is_binary(volume) <- volume(record),
         path when is_binary(path) <- relative_path(record),
         {:ok, entries} <- FileExplorer.list(volume, path) do
      {:ok, VolumeRecords.from_entries(entries, volume, path)}
    end
  end

  def to_storage_map(%Record{} = record) do
    %{
      "id" => record.id,
      "kind" => to_string(record.kind),
      "name" => record.name,
      "path" => record.path,
      "mime_type" => record.mime_type,
      "size" => record.size,
      "modified_at" => encode_datetime(record.modified_at),
      "attributes" => record.attributes || %{}
    }
  end

  def to_storage_map(record) when is_map(record) do
    %{
      "id" => Map.get(record, :id) || Map.get(record, "id"),
      "kind" => record |> kind() |> to_string(),
      "name" => Map.get(record, :name) || Map.get(record, "name"),
      "path" => record_path(record),
      "mime_type" => Map.get(record, :mime_type) || Map.get(record, "mime_type"),
      "size" => Map.get(record, :size) || Map.get(record, "size"),
      "modified_at" =>
        encode_datetime(Map.get(record, :modified_at) || Map.get(record, "modified_at")),
      "attributes" => attributes(record)
    }
  end

  defp attr(record, key), do: record |> attributes() |> Map.get(key)

  defp attributes(%Record{attributes: attrs}) when is_map(attrs), do: attrs
  defp attributes(%{"attributes" => attrs}) when is_map(attrs), do: attrs
  defp attributes(%{attributes: attrs}) when is_map(attrs), do: attrs
  defp attributes(_), do: %{}

  defp record_path(%Record{path: path}), do: path
  defp record_path(%{"path" => path}), do: path
  defp record_path(%{path: path}), do: path
  defp record_path(_), do: nil

  defp normalize_kind(:directory), do: :folder
  defp normalize_kind(:folder), do: :folder
  defp normalize_kind("directory"), do: :folder
  defp normalize_kind("folder"), do: :folder
  defp normalize_kind(:file), do: :file
  defp normalize_kind("file"), do: :file
  defp normalize_kind(kind), do: kind

  defp encode_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp encode_datetime(nil), do: nil
  defp encode_datetime(value), do: value
end
