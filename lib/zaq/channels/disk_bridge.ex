defmodule Zaq.Channels.DiskBridge do
  @moduledoc """
  Bridge that writes files to the local disk via `FileExplorer`.

  Accepts base64-encoded content, always saves with `.md` extension
  regardless of the original filename, and places it under `generated/` unless
  an existing `path` is provided.
  """

  alias Zaq.Ingestion.FileExplorer

  @doc """
  Writes the given file content to disk.

  Params:
    - `filename` (required) — original filename (extension is replaced with .md)
    - `content` (required) — base64-encoded file content
    - `path` (optional) — directory to write into; if it resolves, used as-is,
      otherwise falls back to `generated/`
    - `mime_type` (optional, ignored) — kept for LLM convenience
  """
  @spec create_file(map()) :: {:ok, map()} | {:error, term()}
  def create_file(params) do
    %{filename: filename, content: content} = params
    md_name = Path.rootname(filename) <> ".md"

    rel_path =
      if params[:path] && resolve_path(params[:path]) do
        Path.join(params[:path], md_name)
      else
        "generated/#{md_name}"
      end

    with {:ok, decoded} <- decode_content(content),
         {:ok, abs_path} <- FileExplorer.resolve_path(rel_path),
         :ok <- abs_path |> Path.dirname() |> File.mkdir_p(),
         :ok <- File.write(abs_path, decoded) do
      {:ok,
       %{
         name: md_name,
         path: rel_path,
         mime_type: "text/markdown",
         url: "/bo/files/#{rel_path}",
         size: byte_size(decoded)
       }}
    end
  end

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
