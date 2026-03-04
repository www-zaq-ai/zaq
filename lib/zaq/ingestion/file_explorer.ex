defmodule Zaq.Ingestion.FileExplorer do
  @moduledoc """
  Interacts with the server filesystem for the ingestion pipeline.
  Lists directories/files, gets file info, and handles uploads to the base path.
  """

  @doc """
  Returns the configured base path for ingestion files.
  """
  def base_path do
    Application.get_env(:zaq, Zaq.Ingestion)[:base_path] || "priv/documents"
  end

  @doc """
  Resolves a relative path against the base path.
  Rejects path traversal attempts (e.g. `..`).
  """
  def resolve_path(relative_path) do
    base = Path.expand(base_path())
    full = Path.expand(Path.join(base, relative_path))

    if String.starts_with?(full, base) do
      {:ok, full}
    else
      {:error, :path_traversal}
    end
  end

  @doc """
  Lists files and folders in the given directory relative to base path.
  Returns `{:ok, [%{name, type, size, modified_at}]}`.
  """
  def list(relative_path \\ ".") do
    with {:ok, full_path} <- resolve_path(relative_path),
         true <- File.dir?(full_path) do
      entries =
        full_path
        |> File.ls!()
        |> Enum.sort()
        |> Enum.map(fn name ->
          entry_path = Path.join(full_path, name)
          stat = File.stat!(entry_path, time: :posix)

          %{
            name: name,
            type: if(stat.type == :directory, do: :directory, else: :file),
            size: stat.size,
            modified_at: stat.mtime |> DateTime.from_unix!()
          }
        end)

      {:ok, entries}
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
      {:ok,
       %{
         name: Path.basename(full_path),
         type: if(stat.type == :directory, do: :directory, else: :file),
         size: stat.size,
         modified_at: stat.mtime |> DateTime.from_unix!()
       }}
    else
      {:error, reason} -> {:error, reason}
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
end
