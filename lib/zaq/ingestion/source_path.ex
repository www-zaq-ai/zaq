defmodule Zaq.Ingestion.SourcePath do
  @moduledoc """
  Shared helpers for converting between filesystem paths and document sources.

  Keeps source normalization and volume-aware path mapping consistent across
  ingestion, LiveView, and pipeline modules.
  """

  alias Zaq.Ingestion.FileExplorer

  @doc """
  Normalizes relative paths produced by the UI (e.g. strips leading "./").
  """
  def normalize_relative("./" <> rest), do: rest
  def normalize_relative(path), do: path

  @doc """
  Builds a canonical volume-prefixed source for a relative path.
  """
  def build_source(volume_name, relative_path) do
    normalized = normalize_relative(relative_path)

    cond do
      normalized in ["", "."] -> volume_name
      normalized == volume_name -> normalized
      String.starts_with?(normalized, "#{volume_name}/") -> normalized
      true -> Path.join([volume_name, normalized])
    end
  end

  @doc """
  Returns both legacy and canonical candidates for source lookup.
  """
  def source_candidates(volume_name, relative_path) do
    normalized = normalize_relative(relative_path)

    [normalized, build_source(volume_name, normalized)]
    |> Enum.uniq()
  end

  @doc """
  Builds a new source preserving the style of an existing source.

  If `existing_source` is volume-prefixed for the given volume, the result is
  also volume-prefixed. Otherwise the result is relative-only.
  """
  def remap_source(existing_source, volume_name, new_relative_path) do
    normalized_new = normalize_relative(new_relative_path)

    if is_binary(existing_source) and String.starts_with?(existing_source, "#{volume_name}/") do
      build_source(volume_name, normalized_new)
    else
      normalized_new
    end
  end

  @doc """
  Splits a source into `{volume_name, relative_path}`.

  Falls back to `fallback_volume` when source is not explicitly volume-prefixed.
  """
  def split_source(source, fallback_volume, volumes \\ nil) do
    normalized = normalize_relative(source)
    volumes = volumes || FileExplorer.list_volumes()

    case String.split(normalized, "/", parts: 2) do
      [volume, rest] when rest != "" and is_map_key(volumes, volume) ->
        {volume, rest}

      _ ->
        {fallback_volume, normalized}
    end
  end

  @doc """
  Converts an absolute file path to a document source.

  In multi-volume mode, returns a volume-prefixed source.
  In single-volume mode, returns a path relative to base path.
  Falls back to basename if path is outside known roots.
  """
  def absolute_to_source(file_path) do
    expanded = Path.expand(file_path)
    configured_volumes = configured_volumes()

    if map_size(configured_volumes) > 0 do
      volumes = FileExplorer.list_volumes()

      case find_volume_for_path(volumes, expanded) do
        {volume_name, root} ->
          {:ok, build_source(volume_name, relative_to_root(expanded, root))}

        nil ->
          {:ok, Path.basename(file_path)}
      end
    else
      base = FileExplorer.base_path() |> Path.expand()

      relative =
        case relative_to_root(expanded, base) do
          nil -> Path.basename(file_path)
          "" -> Path.basename(file_path)
          rel -> rel
        end

      {:ok, normalize_relative(relative)}
    end
  end

  @doc """
  Resolves the volume root that contains an absolute path.

  Falls back to configured base path for backward compatibility.
  """
  def volume_root_for_absolute(path) do
    expanded = Path.expand(path)

    FileExplorer.list_volumes()
    |> Enum.find_value(fn {_name, root} ->
      if path_under_root?(expanded, root), do: root
    end)
    |> case do
      nil -> FileExplorer.base_path()
      root -> root
    end
  end

  defp configured_volumes do
    Application.get_env(:zaq, Zaq.Ingestion, [])
    |> Keyword.get(:volumes, %{})
  end

  defp find_volume_for_path(volumes, expanded_path) do
    Enum.find(volumes, fn {_name, root} ->
      path_under_root?(expanded_path, root)
    end)
  end

  defp relative_to_root(path, root) do
    expanded_root = Path.expand(root)
    prefix = expanded_root <> "/"

    if String.starts_with?(path, prefix) do
      String.replace_prefix(path, prefix, "")
    else
      nil
    end
  end

  defp path_under_root?(path, root) do
    expanded_root = Path.expand(root)
    path == expanded_root or String.starts_with?(path, expanded_root <> "/")
  end
end
