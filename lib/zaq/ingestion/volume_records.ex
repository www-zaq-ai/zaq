defmodule Zaq.Ingestion.VolumeRecords do
  @moduledoc """
  Converts local ingestion volume entries into canonical `Zaq.Contracts.Record` values.

  The local volume remains the source of truth for browsing. This module only adapts
  filesystem entries into the same record shape that future external data sources
  will pass to the BO ingestion UI.
  """

  alias Zaq.Contracts.Record
  alias Zaq.Event
  alias Zaq.Ingestion.{Document, FileExplorer, SourcePath}

  @local_provider "disk"

  @doc "Converts local volume directory entries into canonical records."
  @spec from_entries([map()], String.t() | nil, String.t()) :: [Record.t()]
  def from_entries(entries, volume_name, current_dir) when is_list(entries) do
    document_ids = document_ids_by_source(entries, volume_name, current_dir)
    Enum.map(entries, &from_entry(&1, volume_name, current_dir, document_ids))
  end

  @doc "Builds a canonical record for a path inside a local volume."
  @spec from_path(String.t() | nil, String.t()) :: {:ok, Record.t()} | {:error, term()}
  def from_path(volume_name, path) do
    normalized_path = SourcePath.normalize_relative(path)

    with {:ok, entry} <- file_info(volume_name, normalized_path) do
      {:ok, from_entry(entry, volume_name, Path.dirname(normalized_path))}
    end
  end

  @doc "Converts one local volume entry into a canonical record."
  @spec from_entry(map(), String.t() | nil, String.t(), map() | nil) :: Record.t()
  def from_entry(entry, volume_name, current_dir, document_ids \\ nil) do
    relative_path = current_dir |> Path.join(entry.name) |> SourcePath.normalize_relative()
    kind = entry_kind(entry)
    source = relative_path |> SourcePath.normalize_relative() |> source_for(volume_name)
    id = record_id(volume_name, relative_path, document_ids)

    %Record{
      id: id,
      kind: kind,
      name: entry.name,
      path: relative_path,
      mime_type: mime_type(kind, entry.name),
      materializing_event: materializing_event(kind, id),
      size: Map.get(entry, :size),
      modified_at: Map.get(entry, :modified_at),
      attributes: %{
        "provider" => @local_provider,
        "volume" => volume_name,
        "relative_path" => relative_path,
        "source" => source
      },
      raw: %{local_entry: entry}
    }
  end

  @doc """
  Returns the identifier for an entry on a local volume.

  An ingested file answers with its `documents.id`, so the id on a listed record is the one
  a caller hands back to fetch, download, or delete that file. Folders and files with no
  document row fall back to a stable volume-path identifier — there is no document to name.

  Pass `document_ids` (a source-to-id map) to resolve a whole listing without a query per
  entry; `from_entries/3` builds it.
  """
  @spec record_id(String.t() | nil, String.t(), map() | nil) :: String.t()
  def record_id(volume_name, relative_path, document_ids \\ nil) do
    case document_id(volume_name, relative_path, document_ids) do
      nil -> Enum.join([@local_provider, volume_name || "default", relative_path], ":")
      id -> to_string(id)
    end
  end

  # One query per listing rather than one per entry — `from_entries/3` resolves the page up
  # front and every entry reads its id out of the result.
  defp document_ids_by_source(entries, volume_name, current_dir) do
    entries
    |> Enum.flat_map(fn entry ->
      current_dir
      |> Path.join(entry.name)
      |> SourcePath.normalize_relative()
      |> then(&source_candidates(volume_name, &1))
    end)
    |> Document.list_by_sources()
    |> Map.new(&{&1.source, &1.id})
  end

  defp document_id(volume_name, relative_path, nil) do
    volume_name
    |> source_candidates(relative_path)
    |> Enum.find_value(fn source ->
      case Document.get_by_source(source) do
        %Document{id: id} -> id
        _ -> nil
      end
    end)
  end

  defp document_id(volume_name, relative_path, document_ids) when is_map(document_ids) do
    volume_name
    |> source_candidates(relative_path)
    |> Enum.find_value(&Map.get(document_ids, &1))
  end

  # A volume-prefixed candidate has no meaning without a volume — single-volume deployments
  # store the bare relative path.
  defp source_candidates(nil, relative_path), do: [SourcePath.normalize_relative(relative_path)]

  defp source_candidates(volume_name, relative_path),
    do: SourcePath.source_candidates(volume_name, relative_path)

  defp file_info(nil, path), do: FileExplorer.file_info(path)
  defp file_info(volume_name, path), do: FileExplorer.file_info(volume_name, path)

  defp entry_kind(%{type: :directory}), do: :folder
  defp entry_kind(_entry), do: :file

  # A volume entry carries no declared type, so the extension is all there is to go on.
  defp mime_type(:file, name), do: MIME.from_path(name)
  defp mime_type(_kind, _name), do: nil

  # A record travels without its bytes — reading every file a listing names would be wasted
  # work. This is the hop that fetches them when a caller actually wants the content. A
  # folder has nothing to materialize.
  defp materializing_event(:file, id),
    do: Event.new(%{file_id: id}, :ingestion, opts: [action: :materialize_record])

  defp materializing_event(_kind, _id), do: nil

  defp source_for(relative_path, nil), do: relative_path

  defp source_for(relative_path, volume_name) do
    volume_name
    |> SourcePath.source_candidates(relative_path)
    |> List.first()
  end
end
