defmodule Zaq.Channels.DiskBridge do
  @moduledoc """
  DataSource bridge that writes files to the local ZAQ volume via `FileExplorer`.

  Implements the `create_file/2` callback of `Zaq.Channels.DataSourceBridge`, so
  `provider: "disk"` travels the same path as remote providers:
  `Zaq.Agent.Tools.DataSource.CreateDocument` -> `:data_source_create_file` ->
  `DataSourceBridge.create_file/2` -> this bridge.

  The file extension is derived from the MIME type (defaults to `.md`) and the
  file is placed under `generated/` unless a resolvable `path` is provided.
  """

  alias Zaq.Ingestion.FileExplorer

  @default_mime_type "text/markdown"
  @default_dir "generated"

  @doc """
  Creates a file on disk and returns the standard datasource
  `%{status: "created", record: ...}` shape.

  Accepts atom- or string-keyed params: datasource agent tools dispatch string
  keys, and the event request map is caller-built, so neither shape is assumed.

  Params:
    - `name` (or `filename`, required) — extension is derived from the MIME type
    - `content` (optional) — plain text; omitted creates an empty document
    - `path` (optional) — directory to write into; falls back to `generated/`
      when it does not resolve
    - `mime_type` (optional) — defaults to `text/markdown`

  Provider keys with no disk equivalent (`parent_id`, `config_id`) are ignored.
  """
  @spec create_file(map(), map()) :: {:ok, map()} | {:error, term()}
  def create_file(_config, params) when is_map(params) do
    with {:ok, filename} <- fetch_filename(params),
         {:ok, content} <- fetch_content(params) do
      write_file(filename, content, get_param(params, :path), get_param(params, :mime_type))
    end
  end

  defp write_file(filename, content, path, mime_type) do
    ext = mime_to_ext(mime_type || @default_mime_type)
    out_name = Path.rootname(filename) <> ext
    rel_path = build_rel_path(path, out_name)

    with {:ok, abs_path} <- FileExplorer.resolve_path(rel_path),
         :ok <- abs_path |> Path.dirname() |> File.mkdir_p(),
         :ok <- File.write(abs_path, content) do
      {:ok,
       %{
         status: "created",
         record: %{
           id: rel_path,
           name: out_name,
           path: rel_path,
           mime_type: ext_to_mime(ext),
           size: byte_size(content)
         }
       }}
    end
  end

  defp build_rel_path(path, out_name) when is_binary(path) do
    case FileExplorer.resolve_path(path) do
      {:ok, _} -> Path.join(path, out_name)
      _ -> Path.join(@default_dir, out_name)
    end
  end

  defp build_rel_path(_path, out_name), do: Path.join(@default_dir, out_name)

  defp fetch_filename(params) do
    case get_param(params, :name) || get_param(params, :filename) do
      name when is_binary(name) ->
        if String.trim(name) == "", do: {:error, :missing_name}, else: {:ok, name}

      _ ->
        {:error, :missing_name}
    end
  end

  defp fetch_content(params) do
    case get_param(params, :content) do
      nil -> {:ok, ""}
      content when is_binary(content) -> {:ok, content}
      _ -> {:error, :invalid_content}
    end
  end

  defp get_param(params, key) do
    Map.get(params, key) || Map.get(params, Atom.to_string(key))
  end

  defp mime_to_ext("text/plain"), do: ".txt"
  defp mime_to_ext(_), do: ".md"

  defp ext_to_mime(".txt"), do: "text/plain"
  defp ext_to_mime(_), do: "text/markdown"
end
