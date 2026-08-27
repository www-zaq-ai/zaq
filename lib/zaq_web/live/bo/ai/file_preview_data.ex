defmodule ZaqWeb.Live.BO.AI.FilePreviewData do
  @moduledoc """
  Shared preview payload builder used by BO file preview surfaces.
  """

  alias Zaq.Contracts.Record
  alias Zaq.Ingestion
  alias Zaq.Ingestion.Document
  alias Zaq.Ingestion.ExternalSource
  alias Zaq.Ingestion.Python.Steps.{DocxToMd, XlsxToMd}
  alias Zaq.Materialization
  alias Zaq.Storage.FileExplorer
  alias ZaqWeb.Helpers.Markdown
  alias ZaqWeb.Live.BO.AI.BOActor
  alias ZaqWeb.PreviewReference

  @markdown_extension ".md"
  @text_extensions ~w(.txt)
  @image_extensions ~w(.png .jpg .jpeg .gif .webp)
  @pdf_extension ".pdf"
  @docx_extension ".docx"
  @xlsx_extensions ~w(.xlsx .xls .csv)

  @previewable_extensions [
    @markdown_extension,
    @pdf_extension,
    @docx_extension
    | @text_extensions ++ @image_extensions ++ @xlsx_extensions
  ]

  @spec previewable_path?(String.t()) :: boolean()
  def previewable_path?(path) when is_binary(path) and path != "" do
    previewable_filename?(path) || previewable_document_reference?(path)
  end

  def previewable_path?(_), do: false

  defp previewable_document_reference?(source) do
    source
    |> Document.get_by_source()
    |> case do
      %Document{} = document -> previewable_document?(document)
      _ -> false
    end
  end

  defp previewable_document?(%Document{} = document) do
    metadata = document.metadata || %{}
    name = metadata["provider_name"] || document.title || document.source

    previewable_filename?(name)
  end

  defp previewable_filename?(path) when is_binary(path) and path != "" do
    path
    |> Path.extname()
    |> String.downcase()
    |> then(&(&1 in @previewable_extensions))
  end

  defp previewable_filename?(_), do: false

  @spec load(String.t() | Record.t(), map()) :: {:ok, map()} | {:error, :unauthorized}
  def load(input, current_user), do: load(input, current_user, [])

  @spec load(String.t() | Record.t(), map(), keyword()) :: {:ok, map()} | {:error, :unauthorized}
  def load(%Record{} = record, current_user, opts) do
    relative_path = record_source(record)

    if Ingestion.can_access_file?(relative_path, current_user) do
      record
      |> materialized_record(current_user, opts)
      |> case do
        {:ok, %{record: %Record{} = materialized}} ->
          {:ok, preview_from_record(materialized, record, current_user)}

        {:error, _reason} ->
          {:ok, unavailable_preview(relative_path, filename(record), ext(record))}
      end
    else
      {:error, :unauthorized}
    end
  end

  def load(relative_path, current_user, opts) do
    if Ingestion.can_access_file?(relative_path, current_user) do
      case load_document_reference(relative_path, current_user, opts) do
        {:ok, preview} ->
          {:ok, preview}

        :fallback ->
          load_legacy_path(relative_path)
      end
    else
      {:error, :unauthorized}
    end
  end

  @spec load_raw(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def load_raw(token, current_user) do
    with {:ok, payload} <- PreviewReference.verify(token, current_user),
         source when is_binary(source) <- payload["source"],
         true <- Ingestion.can_access_file?(source, current_user) || {:error, :unauthorized},
         {:ok, %{record: %Record{} = record}} <-
           Materialization.materialize(
             payload["handle"],
             materialization_context(current_user),
             "Preview materialization failed",
             %{"encoding" => "base64"}
           ),
         {:ok, content} <- decode_content(record.content, record.attributes) do
      filename = payload["filename"] || filename(record)

      {:ok,
       %{
         content: content,
         filename: filename,
         content_type: payload["mime_type"] || MIME.from_path(filename)
       }}
    end
  end

  defp load_document_reference(relative_path, current_user, opts) do
    case Document.get_by_source(relative_path) do
      %Document{metadata: %{"materialization_handle" => handle}} = doc when is_binary(handle) ->
        doc
        |> record_from_document(handle)
        |> load(current_user, opts)

      _ ->
        :fallback
    end
  end

  defp load_legacy_path(relative_path) do
    filename = Path.basename(relative_path)
    ext = relative_path |> Path.extname() |> String.downcase()

    result =
      with {:ok, full_path} <- FileExplorer.resolve_path(relative_path),
           false <- File.dir?(full_path),
           {:ok, stat} <- File.stat(full_path, time: :posix) do
        {:ok, full_path, stat}
      else
        true -> {:error, :is_directory}
        {:error, reason} -> {:error, reason}
      end

    case result do
      {:ok, full_path, stat} ->
        {kind, content, rendered_html} = load_content(full_path, ext)

        {:ok,
         %{
           relative_path: relative_path,
           filename: filename,
           ext: ext,
           kind: kind,
           content: content,
           rendered_html: rendered_html,
           file_size: stat.size,
           modified_at: stat.mtime |> DateTime.from_unix!(),
           raw_url: "/bo/files/#{relative_path}"
         }}

      {:error, _reason} ->
        {:ok, not_found_preview(relative_path, filename, ext)}
    end
  end

  defp preview_from_record(%Record{} = materialized, %Record{} = original, current_user) do
    name = filename(original)
    ext = ext(original)
    raw_url = raw_url(original, current_user)
    {kind, content, rendered_html} = load_content_from_record(materialized, ext, name)

    %{
      relative_path: record_source(original),
      filename: name,
      ext: ext,
      kind: kind,
      content: content,
      rendered_html: rendered_html,
      file_size: original.size || materialized.size,
      modified_at: original.modified_at || materialized.modified_at,
      raw_url: raw_url
    }
  end

  defp materialized_record(%Record{materialization_handle: handle}, current_user, opts)
       when is_binary(handle) do
    Materialization.materialize(
      handle,
      materialization_context(current_user, opts),
      "Preview materialization failed"
    )
  end

  defp materialized_record(%Record{content: nil}, _current_user, _opts), do: {:error, :no_content}
  defp materialized_record(%Record{} = record, _current_user, _opts), do: {:ok, %{record: record}}

  defp load_content_from_record(%Record{} = record, ext, filename) do
    case decode_content(record.content, record.attributes) do
      {:ok, binary} -> load_content(binary, ext, filename)
      {:error, _reason} -> {:binary, nil, nil}
    end
  end

  defp decode_content(content, attrs) when is_binary(content) do
    case encoding(attrs) do
      "base64" -> Base.decode64(content)
      _ -> {:ok, content}
    end
  end

  defp decode_content(_content, _attrs), do: {:error, :no_content}

  defp encoding(attrs) when is_map(attrs),
    do: Map.get(attrs, "encoding") || Map.get(attrs, :encoding)

  defp encoding(_attrs), do: nil

  defp load_content(binary, @markdown_extension, _filename) do
    {:markdown, binary, render_html(binary, ".md")}
  end

  defp load_content(binary, ext, _filename) when ext in @text_extensions do
    {:text, binary, nil}
  end

  defp load_content(_binary, ext, _filename) when ext in @image_extensions, do: {:image, nil, nil}
  defp load_content(_binary, @pdf_extension, _filename), do: {:pdf, nil, nil}

  defp load_content(binary, @docx_extension, filename) do
    binary_tmp_path(filename, @docx_extension, binary, fn full_path ->
      load_content(full_path, @docx_extension)
    end)
  end

  defp load_content(binary, ext, filename) when ext in @xlsx_extensions do
    binary_tmp_path(filename, ext, binary, fn full_path ->
      load_content(full_path, ext)
    end)
  end

  defp load_content(_binary, _ext, _filename), do: {:binary, nil, nil}

  defp load_content(full_path, @markdown_extension) do
    case File.read(full_path) do
      {:ok, content} -> {:markdown, content, render_html(content, ".md")}
      {:error, _} -> {:error, nil, nil}
    end
  end

  defp load_content(full_path, ext) when ext in @text_extensions do
    case File.read(full_path) do
      {:ok, content} -> {:text, content, nil}
      {:error, _} -> {:error, nil, nil}
    end
  end

  defp load_content(_full_path, ext) when ext in @image_extensions, do: {:image, nil, nil}
  defp load_content(_full_path, @pdf_extension), do: {:pdf, nil, nil}

  defp load_content(full_path, @docx_extension) do
    md_path = tmp_md_path(full_path, @docx_extension)

    result =
      case DocxToMd.run(full_path, md_path) do
        {:ok, _} -> File.read(md_path)
        error -> error
      end

    _ = File.rm(md_path)

    case result do
      {:ok, content} ->
        {:markdown, content, render_html(content, ".md")}

      _ ->
        {:binary, nil, nil}
    end
  end

  defp load_content(full_path, ext) when ext in @xlsx_extensions do
    md_path = tmp_md_path(full_path, ext)

    result =
      case XlsxToMd.run(full_path, md_path) do
        {:ok, _} -> File.read(md_path)
        error -> error
      end

    _ = File.rm(md_path)

    case result do
      {:ok, content} ->
        {:markdown, content, render_html(content, ".md")}

      _ ->
        {:binary, nil, nil}
    end
  end

  defp load_content(_full_path, _ext), do: {:binary, nil, nil}

  defp record_from_document(%Document{} = doc, handle) do
    metadata = doc.metadata || %{}
    name = metadata["provider_name"] || doc.title || Path.basename(doc.source)

    %Record{
      id: metadata["provider_file_id"] || doc.source,
      kind: :file,
      name: name,
      path: doc.source,
      mime_type: metadata["provider_mime_type"] || MIME.from_path(name),
      size: metadata["provider_size"],
      modified_at: doc.updated_at,
      materialization_handle: handle,
      attributes: %{
        "provider" => metadata["provider"],
        "config_id" => metadata["provider_config_id"],
        "provider_record_id" => metadata["provider_file_id"] || doc.source,
        "source" => doc.source
      }
    }
  end

  defp not_found_preview(relative_path, filename, ext) do
    %{
      relative_path: relative_path,
      filename: filename,
      ext: ext,
      kind: :not_found,
      content: nil,
      rendered_html: nil,
      file_size: nil,
      modified_at: nil,
      raw_url: nil
    }
  end

  defp unavailable_preview(relative_path, filename, ext) do
    %{
      relative_path: relative_path,
      filename: filename,
      ext: ext,
      kind: :binary,
      content: nil,
      rendered_html: nil,
      file_size: nil,
      modified_at: nil,
      raw_url: nil
    }
  end

  defp record_source(%Record{} = record) do
    if ExternalSource.external?(record),
      do: ExternalSource.source(record),
      else: local_record_source(record)
  end

  defp local_record_source(%Record{attributes: attrs, path: path, id: id}) do
    source = if is_map(attrs), do: Map.get(attrs, "source") || Map.get(attrs, :source)
    source || path || id
  end

  defp filename(%Record{} = record) do
    cond do
      is_binary(record.name) and record.name != "" -> record.name
      is_binary(record.path) -> Path.basename(record.path)
      is_binary(record.id) -> Path.basename(record.id)
      true -> "file"
    end
  end

  defp ext(%Record{} = record), do: record |> filename() |> Path.extname() |> String.downcase()

  defp raw_url(%Record{} = record, current_user) do
    case PreviewReference.sign_record(record, current_user) do
      token when is_binary(token) -> "/bo/files/ref/#{token}"
      _ -> nil
    end
  end

  defp materialization_context(current_user, opts \\ []) do
    context = %{
      actor: BOActor.build(current_user)
    }

    case Keyword.get(opts, :node_router) do
      nil -> context
      node_router -> Map.put(context, :node_router, node_router)
    end
  end

  defp binary_tmp_path(filename, ext, binary, fun) do
    full_path = tmp_source_path(filename, ext)

    try do
      File.write!(full_path, binary)
      fun.(full_path)
    after
      _ = File.rm(full_path)
    end
  end

  defp tmp_source_path(filename, ext) do
    basename = filename |> Path.basename(ext) |> String.replace(~r/[^A-Za-z0-9_.-]/, "_")
    unique = System.unique_integer([:positive])
    Path.join(System.tmp_dir!(), "#{basename}-#{unique}#{ext}")
  end

  defp render_html(content, ".md") do
    Markdown.render(content)
  end

  defp render_html(_content, _ext), do: nil

  defp tmp_md_path(full_path, ext) do
    basename = Path.basename(full_path, ext)
    unique = System.unique_integer([:positive])
    Path.join(System.tmp_dir!(), "#{basename}-#{unique}.md")
  end
end
