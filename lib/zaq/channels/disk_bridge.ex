defmodule Zaq.Channels.DiskBridge do
  @moduledoc """
  Bridge that writes files to the local disk via `FileExplorer`.

  Accepts base64-encoded content, derives the file extension from the provided
  MIME type (defaults to `.md`), and places it under `generated/` unless
  an existing `path` is provided.
  """

  alias Zaq.Ingestion.FileExplorer

  @doc """
  DataSourceBridge-compatible entry point. Base64-encodes `data` into `content`
  and delegates to `create_file/1`.
  """
  @spec create_file(map(), map()) :: {:ok, map()} | {:error, term()}
  def create_file(_config, params) do
    params
    |> Map.put(:filename, params.name)
    |> Map.put(:content, Base.encode64(params.content))
    |> Map.drop([:name])
    |> create_file()
  end

  @doc """
  Writes the given file content to disk.

  Params:
    - `filename` (required) — original filename (extension is derived from MIME type)
    - `content` (required) — base64-encoded file content
    - `path` (optional) — directory to write into; if it resolves, used as-is,
      otherwise falls back to `generated/`
    - `mime_type` (optional) — MIME type used to determine extension; defaults to text/markdown
  """
  @spec create_file(map()) :: {:ok, map()} | {:error, term()}
  def create_file(params) do
    %{filename: filename, content: content} = params
    mime_type = Map.get(params, :mime_type, "text/markdown")
    ext = mime_to_ext(mime_type)
    out_name = Path.rootname(filename) <> ext
    out_mime = ext_to_mime(ext)

    rel_path =
      if params[:path] && resolve_path(params[:path]) do
        Path.join(params[:path], out_name)
      else
        "generated/#{out_name}"
      end

    with {:ok, decoded} <- decode_content(content),
         {:ok, abs_path} <- FileExplorer.resolve_path(rel_path),
         :ok <- abs_path |> Path.dirname() |> File.mkdir_p(),
         :ok <- File.write(abs_path, decoded) do
      {:ok,
       %{
         name: out_name,
         path: rel_path,
         mime_type: out_mime,
         size: byte_size(decoded)
       }}
    end
  end

  defp mime_to_ext("text/plain"), do: ".txt"
  defp mime_to_ext(_), do: ".md"

  defp ext_to_mime(".txt"), do: "text/plain"
  defp ext_to_mime(_), do: "text/markdown"

  defp decode_content(content) do
    case Base.decode64(content) do
      {:ok, decoded} -> {:ok, decoded}
      _ -> {:error, :invalid_base64}
    end
  end

  defp resolve_path(path) do
    case FileExplorer.resolve_path(path) do
      {:ok, _} -> true
      _ -> false
    end
  end
end
