defmodule Zaq.Ingestion.VolumeRecords do
  @moduledoc """
  Converts local ingestion volume entries into canonical `Zaq.Contracts.Record` values.

  The local volume remains the source of truth for browsing. This module only adapts
  filesystem entries into the same record shape that future external data sources
  will pass to the BO ingestion UI.
  """

  alias Zaq.Contracts.Record
  alias Zaq.Ingestion.{FileExplorer, SourcePath}

  @local_provider "zaq_local"

  @doc "Converts local volume directory entries into canonical records."
  @spec from_entries([map()], String.t() | nil, String.t()) :: [Record.t()]
  def from_entries(entries, volume_name, current_dir) when is_list(entries) do
    Enum.map(entries, &from_entry(&1, volume_name, current_dir))
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
  @spec from_entry(map(), String.t() | nil, String.t()) :: Record.t()
  def from_entry(entry, volume_name, current_dir) do
    relative_path = current_dir |> Path.join(entry.name) |> SourcePath.normalize_relative()
    kind = entry_kind(entry)
    source = relative_path |> SourcePath.normalize_relative() |> source_for(volume_name)

    %Record{
      id: record_id(volume_name, relative_path),
      kind: kind,
      name: entry.name,
      path: relative_path,
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

  @doc "Builds a stable local-volume record identifier."
  @spec record_id(String.t() | nil, String.t()) :: String.t()
  def record_id(volume_name, relative_path),
    do: Enum.join([@local_provider, volume_name || "default", relative_path], ":")

  defp file_info(nil, path), do: FileExplorer.file_info(path)
  defp file_info(volume_name, path), do: FileExplorer.file_info(volume_name, path)

  defp entry_kind(%{type: :directory}), do: :folder
  defp entry_kind(_entry), do: :file

  defp source_for(relative_path, nil), do: relative_path

  defp source_for(relative_path, volume_name) do
    volume_name
    |> SourcePath.source_candidates(relative_path)
    |> List.first()
  end
end
