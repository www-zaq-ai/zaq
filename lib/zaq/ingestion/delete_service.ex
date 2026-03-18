defmodule Zaq.Ingestion.DeleteService do
  @moduledoc false

  import Ecto.Query

  alias Zaq.Ingestion.{Document, FileExplorer, Sidecar, SourcePath}
  alias Zaq.Repo

  def delete_path(volume_name, path, type, volumes \\ nil)

  def delete_path(volume_name, path, "directory", volumes) do
    volumes = volumes || FileExplorer.list_volumes()
    delete_directory_path(volume_name, path, volumes)
  end

  def delete_path(volume_name, path, _type, volumes) do
    volumes = volumes || FileExplorer.list_volumes()
    normalized_path = SourcePath.normalize_relative(path)
    sources = SourcePath.source_candidates(volume_name, normalized_path)

    sidecar_sources =
      from(d in Document, where: d.source in ^sources)
      |> Repo.all()
      |> Enum.map(&Sidecar.sidecar_source/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    delete_documents_by_sources(sources ++ sidecar_sources)

    sidecar_results =
      Enum.map(sidecar_sources, fn sidecar_source ->
        {sidecar_volume, relative_path} =
          SourcePath.split_source(sidecar_source, volume_name, volumes)

        normalize_delete_result(FileExplorer.delete(sidecar_volume, relative_path))
      end)

    case FileExplorer.delete(volume_name, path) do
      :ok -> first_error_or_ok(sidecar_results)
      error -> error
    end
  end

  def delete_paths(volume_name, paths, volumes \\ nil) do
    volumes = volumes || FileExplorer.list_volumes()

    Enum.map(paths, fn path ->
      case FileExplorer.file_info(volume_name, path) do
        {:ok, %{type: :directory}} ->
          {path, delete_path(volume_name, path, "directory", volumes)}

        {:ok, %{type: :file}} ->
          {path, delete_path(volume_name, path, "file", volumes)}

        _ ->
          {path, {:error, :not_found}}
      end
    end)
  end

  defp delete_documents_by_sources(sources) do
    sources
    |> Enum.uniq()
    |> then(fn unique_sources ->
      from(d in Document, where: d.source in ^unique_sources)
      |> Repo.all()
      |> Enum.each(&Document.delete/1)
    end)
  end

  defp normalize_delete_result(:ok), do: :ok
  defp normalize_delete_result({:error, :enoent}), do: :ok
  defp normalize_delete_result(other), do: other

  defp delete_directory_path(volume_name, path, volumes) do
    case FileExplorer.list(volume_name, path) do
      {:ok, entries} ->
        results =
          Enum.map(entries, fn entry ->
            delete_entry_in_directory(volume_name, path, entry, volumes)
            |> normalize_delete_result()
          end)

        case first_error_or_ok(results) do
          :ok -> normalize_delete_result(FileExplorer.delete_directory(volume_name, path))
          error -> error
        end

      {:error, :enoent} ->
        :ok

      error ->
        error
    end
  end

  defp delete_entry_in_directory(
         volume_name,
         parent_path,
         %{name: name, type: :directory},
         volumes
       ) do
    delete_directory_path(volume_name, child_path(parent_path, name), volumes)
  end

  defp delete_entry_in_directory(volume_name, parent_path, %{name: name}, volumes) do
    delete_path(volume_name, child_path(parent_path, name), "file", volumes)
  end

  defp child_path(".", name), do: name
  defp child_path(parent_path, name), do: Path.join(parent_path, name)

  defp first_error_or_ok(results) do
    Enum.find(results, :ok, fn result -> result != :ok end)
  end
end
