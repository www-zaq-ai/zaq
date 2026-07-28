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

  # Mime types whose content is assumed Base64 when the caller does not say.
  # Binary cannot travel as a tool result — it is not valid UTF-8 and would
  # swamp the model's context — so an agent passes the *encoded* string through
  # `content` and the bytes are materialised here, at the write. An in-process
  # caller that already holds bytes declares `content_encoding: "raw"` instead.
  #
  # The set is explicit rather than "anything not text/*" so that a textual
  # payload with an exotic mime type (`application/json`) is still written
  # literally instead of being mistaken for an encoded one.
  @binary_exts %{
    "image/png" => ".png",
    "image/jpeg" => ".jpg",
    "image/gif" => ".gif",
    "image/webp" => ".webp",
    "application/pdf" => ".pdf",
    "application/zip" => ".zip"
  }

  @text_exts %{
    "text/plain" => ".txt",
    "text/markdown" => ".md"
  }

  @exts Map.merge(@text_exts, @binary_exts)
  @mimes Map.new(@exts, fn {mime, ext} -> {ext, mime} end)

  @doc """
  Creates a file on disk and returns the standard datasource
  `%{status: "created", record: ...}` shape.

  Accepts atom- or string-keyed params: datasource agent tools dispatch string
  keys, and the event request map is caller-built, so neither shape is assumed.

  Params:
    - `name` (or `filename`, required) — extension is derived from the MIME type
    - `content` (optional) — omitted creates an empty document
    - `content_encoding` (optional) — `"raw"` when `content` already holds the
      bytes, `"base64"` when it holds an encoded string. Omitted, a binary
      `mime_type` implies `"base64"` and anything else is written verbatim
    - `path` (optional) — directory to write into; falls back to `generated/`
      when it does not resolve
    - `mime_type` (optional) — defaults to `text/markdown`

  Provider keys with no disk equivalent (`parent_id`, `config_id`) are ignored.
  """
  @spec create_file(map(), map()) :: {:ok, map()} | {:error, term()}
  def create_file(_config, params) when is_map(params) do
    mime_type = get_param(params, :mime_type)
    encoding = get_param(params, :content_encoding)

    with {:ok, filename} <- fetch_filename(params),
         {:ok, content} <- fetch_content(params, mime_type, encoding) do
      write_file(filename, content, get_param(params, :path), mime_type)
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

  defp fetch_content(params, mime_type, encoding) do
    case get_param(params, :content) do
      nil -> {:ok, ""}
      content when is_binary(content) -> decode_content(content, mime_type, encoding)
      _ -> {:error, :invalid_content}
    end
  end

  # `raw` means the caller already holds the bytes — the in-process path, where
  # a generated image arrives decoded. Written verbatim whatever the mime type.
  defp decode_content(content, _mime_type, "raw"), do: {:ok, content}

  defp decode_content(content, _mime_type, "base64"), do: decode_base64(content)

  # With no declaration, a known-binary mime type implies Base64: that is the
  # agent path, where the encoded string is the only form that can cross a tool
  # boundary. Text mime types are written verbatim, so content that merely
  # looks like Base64 ("aGVsbG8=") is not mangled.
  defp decode_content(content, mime_type, nil) when is_map_key(@binary_exts, mime_type),
    do: decode_base64(content)

  defp decode_content(content, _mime_type, nil), do: {:ok, content}

  defp decode_content(_content, _mime_type, encoding),
    do: {:error, {:invalid_content_encoding, encoding}}

  defp decode_base64(content) do
    stripped = String.replace(content, ~r/\s/, "")

    with :error <- Base.decode64(stripped, padding: false),
         :error <- Base.url_decode64(stripped, padding: false) do
      {:error, :invalid_base64}
    end
  end

  defp get_param(params, key) do
    Map.get(params, key) || Map.get(params, Atom.to_string(key))
  end

  defp mime_to_ext(mime_type), do: Map.get(@exts, mime_type, ".md")

  defp ext_to_mime(ext), do: Map.get(@mimes, ext, @default_mime_type)
end
