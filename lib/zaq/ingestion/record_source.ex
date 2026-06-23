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

  @doc "Returns the normalized ingestion kind for a canonical record."
  @spec kind(Record.t()) :: atom()
  def kind(%Record{kind: kind}), do: normalize_kind(kind)

  @doc "Returns the volume-relative path encoded in a canonical record."
  @spec relative_path(Record.t()) :: String.t() | nil
  def relative_path(%Record{} = record),
    do: attr(record, "relative_path") || attr(record, :relative_path) || record_path(record)

  @doc "Returns the local volume name encoded in a canonical record, when present."
  @spec volume(Record.t()) :: String.t() | nil
  def volume(%Record{} = record), do: attr(record, "volume") || attr(record, :volume)

  @doc "Resolves a canonical record into a local filesystem path for processing."
  @spec resolve_path(Record.t()) :: {:ok, String.t()} | {:error, term()}
  def resolve_path(%Record{} = record) do
    case {volume(record), relative_path(record)} do
      {volume, path} when is_binary(volume) and is_binary(path) ->
        FileExplorer.resolve_path(volume, path)

      {nil, path} when is_binary(path) ->
        FileExplorer.resolve_path(path)

      _ ->
        {:error, :unsupported_record_source}
    end
  end

  @doc "Lists child records for a folder record."
  @spec list_children(Record.t()) :: {:ok, [Record.t()]} | {:error, term()}
  def list_children(%Record{} = record) do
    volume = volume(record)

    with path when is_binary(path) <- relative_path(record),
         {:ok, entries} <- list_entries(volume, path) do
      {:ok, VolumeRecords.from_entries(entries, volume, path)}
    end
  end

  @doc "Serializes a canonical record into a JSON-safe map for persistence."
  @spec to_storage_map(Record.t()) :: map()
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

  @doc "Deserializes a persisted source record map into a canonical record."
  @spec from_storage_map(map()) :: {:ok, Record.t()} | {:error, :invalid_source_record}
  def from_storage_map(%{"id" => id, "kind" => kind} = map) do
    {:ok,
     %Record{
       id: id,
       kind: normalize_kind(kind),
       name: Map.get(map, "name"),
       path: Map.get(map, "path"),
       mime_type: Map.get(map, "mime_type"),
       size: Map.get(map, "size"),
       modified_at: decode_datetime(Map.get(map, "modified_at")),
       attributes: Map.get(map, "attributes", %{})
     }}
  end

  def from_storage_map(_), do: {:error, :invalid_source_record}

  defp list_entries(nil, path), do: FileExplorer.list(path)
  defp list_entries(volume, path), do: FileExplorer.list(volume, path)

  defp attr(%Record{} = record, key), do: record |> attributes() |> Map.get(key)

  defp attributes(%Record{attributes: attrs}) when is_map(attrs), do: attrs
  defp attributes(%Record{}), do: %{}

  defp record_path(%Record{path: path}), do: path

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

  defp decode_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> value
    end
  end

  defp decode_datetime(value), do: value
end
