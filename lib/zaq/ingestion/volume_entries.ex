defmodule Zaq.Ingestion.VolumeEntries do
  @moduledoc """
  Fills document identity onto `Zaq.Ingestion.FileExplorer.Entry` values.

  `FileExplorer` reads the filesystem and knows nothing about the `documents` table, so the
  entries it returns carry no `id`. This module resolves that half: an ingested file answers
  with its `documents.id`, so the id on a listed entry is the one a caller hands back to
  fetch, download, or delete that file. Folders and files with no document row fall back to
  a stable volume-path id — there is no document to name.

  Resolving also normalizes `relative_path`, which `FileExplorer` stores as the caller gave
  it.
  """

  alias Zaq.Ingestion.Document
  alias Zaq.Ingestion.FileExplorer
  alias Zaq.Ingestion.FileExplorer.Entry
  alias Zaq.Ingestion.SourcePath

  @local_provider "disk"

  @doc """
  Resolves one entry, or a whole listing.

  A listing takes one document query for the page rather than a query per file: every
  candidate source is read at once and each entry takes its id from the result.
  """
  @spec resolve([Entry.t()] | Entry.t()) :: [Entry.t()] | Entry.t()
  def resolve(entries) when is_list(entries) do
    document_ids = document_ids_by_source(entries)
    Enum.map(entries, &put_identity(&1, document_ids))
  end

  def resolve(%Entry{} = entry), do: put_identity(entry, nil)

  @doc "Reads one path off a volume and resolves the entry it names."
  @spec from_path(String.t() | nil, String.t()) :: {:ok, Entry.t()} | {:error, term()}
  def from_path(volume_name, path) do
    with {:ok, %Entry{} = entry} <- file_info(volume_name, SourcePath.normalize_relative(path)) do
      {:ok, resolve(entry)}
    end
  end

  @doc "Returns the provider name local volume entries answer with."
  @spec local_provider() :: String.t()
  def local_provider, do: @local_provider

  defp put_identity(%Entry{} = entry, document_ids) do
    relative_path = SourcePath.normalize_relative(entry.relative_path || entry.name)
    document_id = document_id(entry.volume, relative_path, document_ids)

    %Entry{
      entry
      | id: entry_id_for(entry.volume, relative_path, document_id),
        relative_path: relative_path,
        source: source_for(entry.volume, relative_path),
        document_id: document_id
    }
  end

  defp entry_id_for(_volume_name, _relative_path, document_id) when not is_nil(document_id),
    do: to_string(document_id)

  defp entry_id_for(volume_name, relative_path, _document_id),
    do: Enum.join([@local_provider, volume_name || "default", relative_path], ":")

  defp document_ids_by_source(entries) do
    entries
    |> Enum.flat_map(fn %Entry{} = entry ->
      entry.volume
      |> source_candidates(SourcePath.normalize_relative(entry.relative_path || entry.name))
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

  defp source_for(nil, relative_path), do: relative_path

  defp source_for(volume_name, relative_path) do
    volume_name
    |> SourcePath.source_candidates(relative_path)
    |> List.first()
  end

  defp file_info(nil, path), do: FileExplorer.file_info(path)
  defp file_info(volume_name, path), do: FileExplorer.file_info(volume_name, path)
end
