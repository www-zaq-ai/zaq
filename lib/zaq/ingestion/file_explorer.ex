defmodule Zaq.Ingestion.FileExplorer do
  @moduledoc """
  Interacts with the server filesystem for the ingestion pipeline.
  Lists directories/files, gets file info, and handles uploads to the base path.

  Supports both single-volume (legacy `base_path`) and multi-volume (`volumes` map)
  configurations. All single-argument functions remain unchanged for backward compat.
  Volume-aware variants accept a `volume_name` as the first argument.
  """

  @doc """
  Returns the configured base path for ingestion files.
  """
  def base_path do
    Application.get_env(:zaq, Zaq.Ingestion)[:base_path] || "priv/documents"
  end

  @doc """
  Returns all configured volumes as `%{name => abs_path}`.

  If a `volumes` map is configured and non-empty, returns it (with expanded paths).
  Otherwise derives a `"default"` volume from `base_path`.
  """
  def list_volumes do
    config = Application.get_env(:zaq, Zaq.Ingestion, [])
    volumes = Keyword.get(config, :volumes, %{})

    if map_size(volumes) > 0 do
      Map.new(volumes, fn {k, v} -> {k, Path.expand(v)} end)
    else
      %{"default" => Path.expand(base_path())}
    end
  end

  @doc """
  Resolves a relative path against the base path (single-volume, legacy).
  Rejects path traversal attempts (e.g. `..`).

  When volumes are configured, automatically detects if the first path segment
  is a known volume name and delegates to the volume-aware `resolve_path/2`.
  This allows preview and file-serving URLs like `/bo/preview/documents/file.pdf`
  to work correctly when `documents` is a configured volume.
  """
  def resolve_path(relative_path) do
    config = Application.get_env(:zaq, Zaq.Ingestion, [])
    configured_volumes = Keyword.get(config, :volumes, %{})

    if map_size(configured_volumes) > 0 do
      case Path.split(relative_path) do
        [vol | rest] when rest != [] and is_map_key(configured_volumes, vol) ->
          resolve_path(vol, Path.join(rest))

        _ ->
          resolve_path_against_base(relative_path)
      end
    else
      resolve_path_against_base(relative_path)
    end
  end

  defp resolve_path_against_base(relative_path) do
    base = Path.expand(base_path())
    full = Path.expand(Path.join(base, relative_path))

    if String.starts_with?(full, base) do
      {:ok, full}
    else
      {:error, :path_traversal}
    end
  end

  @doc """
  Volume-aware path resolution. Resolves `relative_path` against the named volume root.
  Returns `{:ok, abs_path}`, `{:error, :unknown_volume}`, or `{:error, :path_traversal}`.
  """
  def resolve_path(volume_name, relative_path) when is_binary(volume_name) do
    volumes = list_volumes()

    case Map.fetch(volumes, volume_name) do
      {:ok, vol_root} ->
        full = Path.expand(Path.join(vol_root, relative_path))

        if String.starts_with?(full, vol_root) do
          {:ok, full}
        else
          {:error, :path_traversal}
        end

      :error ->
        {:error, :unknown_volume}
    end
  end

  @doc """
  Lists files and folders in the given directory relative to base path.
  Returns `{:ok, [%{name, type, size, modified_at}]}`.
  """
  def list(relative_path \\ ".") do
    with {:ok, full_path} <- resolve_path(relative_path),
         true <- File.dir?(full_path) do
      {:ok, list_entries(full_path)}
    else
      false -> {:error, :not_a_directory}
      error -> error
    end
  end

  @doc """
  Volume-aware variant of `list/1`. Lists entries under `relative_path` within the named volume.
  """
  def list(volume_name, relative_path) when is_binary(volume_name) do
    with {:ok, full_path} <- resolve_path(volume_name, relative_path),
         true <- File.dir?(full_path) do
      {:ok, list_entries(full_path)}
    else
      false -> {:error, :not_a_directory}
      error -> error
    end
  end

  @doc """
  Returns metadata for a single file relative to base path.
  """
  def file_info(relative_path) do
    with {:ok, full_path} <- resolve_path(relative_path),
         {:ok, stat} <- File.stat(full_path, time: :posix) do
      {:ok, build_entry(full_path, stat)}
    end
  end

  @doc """
  Volume-aware variant of `file_info/1`.
  """
  def file_info(volume_name, relative_path) when is_binary(volume_name) do
    with {:ok, full_path} <- resolve_path(volume_name, relative_path),
         {:ok, stat} <- File.stat(full_path, time: :posix) do
      {:ok, build_entry(full_path, stat)}
    end
  end

  @doc """
  Writes a file to the base path. Returns `{:ok, full_path}`.
  """
  def upload(filename, binary) do
    with {:ok, full_path} <- resolve_path(filename),
         :ok <- full_path |> Path.dirname() |> File.mkdir_p(),
         :ok <- File.write(full_path, binary) do
      {:ok, full_path}
    end
  end

  @doc """
  Volume-aware variant of `upload/2`. Writes `binary` to `filename` within the named volume.
  """
  def upload(volume_name, filename, binary) when is_binary(volume_name) do
    with {:ok, full_path} <- resolve_path(volume_name, filename),
         :ok <- full_path |> Path.dirname() |> File.mkdir_p(),
         :ok <- File.write(full_path, binary) do
      {:ok, full_path}
    end
  end

  @doc """
  Deletes a single file relative to base path.
  """
  def delete(relative_path) do
    with {:ok, full_path} <- resolve_path(relative_path) do
      File.rm(full_path)
    end
  end

  @doc """
  Volume-aware variant of `delete/1`.
  """
  def delete(volume_name, relative_path) when is_binary(volume_name) do
    with {:ok, full_path} <- resolve_path(volume_name, relative_path) do
      File.rm(full_path)
    end
  end

  @doc """
  Recursively deletes a directory and all its contents relative to base path.
  """
  def delete_directory(relative_path) do
    with {:ok, full_path} <- resolve_path(relative_path),
         true <- File.dir?(full_path) do
      File.rm_rf(full_path)
      :ok
    else
      false -> {:error, :not_a_directory}
      error -> error
    end
  end

  @doc """
  Volume-aware variant of `delete_directory/1`.
  """
  def delete_directory(volume_name, relative_path) when is_binary(volume_name) do
    with {:ok, full_path} <- resolve_path(volume_name, relative_path),
         true <- File.dir?(full_path) do
      File.rm_rf(full_path)
      :ok
    else
      false -> {:error, :not_a_directory}
      error -> error
    end
  end

  @doc """
  Renames (moves) a file or directory. Both paths are relative to base path.
  """
  def rename(old_relative, new_relative) do
    with {:ok, old_full} <- resolve_path(old_relative),
         {:ok, new_full} <- resolve_path(new_relative) do
      File.rename(old_full, new_full)
    end
  end

  @doc """
  Volume-aware variant of `rename/2`. Both paths are relative to the named volume.
  """
  def rename(volume_name, old_relative, new_relative) when is_binary(volume_name) do
    with {:ok, old_full} <- resolve_path(volume_name, old_relative),
         {:ok, new_full} <- resolve_path(volume_name, new_relative) do
      File.rename(old_full, new_full)
    end
  end

  @doc """
  Creates a directory (including parents) relative to base path.
  """
  def create_directory(relative_path) do
    with {:ok, full_path} <- resolve_path(relative_path) do
      File.mkdir_p(full_path)
    end
  end

  @doc """
  Volume-aware variant of `create_directory/1`.
  """
  def create_directory(volume_name, relative_path) when is_binary(volume_name) do
    with {:ok, full_path} <- resolve_path(volume_name, relative_path) do
      File.mkdir_p(full_path)
    end
  end

  # ── Private helpers ──────────────────────────────────────────────

  defp list_entries(full_path) do
    full_path
    |> File.ls!()
    |> Enum.sort()
    |> Task.async_stream(
      fn name ->
        entry_path = Path.join(full_path, name)
        stat = File.stat!(entry_path, time: :posix)

        %{
          name: name,
          type: if(stat.type == :directory, do: :directory, else: :file),
          size: stat.size,
          modified_at: stat.mtime |> DateTime.from_unix!()
        }
      end,
      max_concurrency: file_stats_concurrency(),
      ordered: true,
      timeout: :infinity
    )
    |> Enum.flat_map(fn
      {:ok, entry} -> [entry]
      {:exit, _} -> []
    end)
  end

  defp file_stats_concurrency do
    default = default_file_stats_concurrency()

    Application.get_env(:zaq, Zaq.Ingestion, [])
    |> Keyword.get(:file_stats_concurrency, default)
    |> normalize_concurrency(default)
  end

  defp default_file_stats_concurrency do
    System.schedulers_online()
    |> Kernel.*(2)
    |> min(32)
    |> max(1)
  end

  defp normalize_concurrency(value, _default) when is_integer(value) and value > 0, do: value
  defp normalize_concurrency(_value, default), do: default

  defp build_entry(full_path, stat) do
    %{
      name: Path.basename(full_path),
      type: if(stat.type == :directory, do: :directory, else: :file),
      size: stat.size,
      modified_at: stat.mtime |> DateTime.from_unix!()
    }
  end
end
