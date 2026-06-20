defmodule Zaq.Ingestion.VolumeRecords do
  @moduledoc """
  Converts local ingestion volume entries into canonical `Zaq.Contracts.Record` values.

  The local volume remains the source of truth for browsing. This module only adapts
  filesystem entries into the same record shape that future external data sources
  will pass to the BO ingestion UI.
  """

  alias Zaq.Contracts.Record
  alias Zaq.Ingestion.SourcePath

  @local_provider "zaq_local"

  def from_entries(entries, volume_name, current_dir) when is_list(entries) do
    Enum.map(entries, &from_entry(&1, volume_name, current_dir))
  end

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

  def record_id(volume_name, relative_path),
    do: Enum.join([@local_provider, volume_name, relative_path], ":")

  defp entry_kind(%{type: :directory}), do: :folder
  defp entry_kind(_entry), do: :file

  defp source_for(relative_path, volume_name) do
    volume_name
    |> SourcePath.source_candidates(relative_path)
    |> List.first()
  end
end
