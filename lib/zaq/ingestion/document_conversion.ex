defmodule Zaq.Ingestion.DocumentConversion do
  @moduledoc """
  Converts a materialized document to Markdown without indexing or saving it.

  A Record supplies the downloaded representation, not permission to use its
  source identity elsewhere. The converter never redeems handles or opens paths
  supplied by the caller.
  """

  alias Zaq.Contracts.Record
  alias Zaq.Ingestion.{ArtifactType, DocumentProcessor, OfficeMarkdown}

  @office_extensions ~w(.docx .pptx .xlsx)
  @text_extensions ~w(.csv .md .markdown)
  @input_extensions [".pdf" | @text_extensions ++ @office_extensions]
  @max_input_bytes 20 * 1024 * 1024
  @max_base64_bytes div(@max_input_bytes + 2, 3) * 4
  @max_markdown_bytes 5 * 1024 * 1024

  @doc """
  Returns Markdown content, a suggested filename and descriptive source metadata.

  `image_handling` defaults to `describe` for PDF and `ignore` for Office. A
  caller-supplied mode must be supported by the downloaded format.
  """
  @spec to_markdown(Record.t(), String.t() | nil) :: {:ok, map()} | {:error, atom()}
  def to_markdown(record, image_handling \\ nil)

  def to_markdown(%Record{id: id, kind: :file, content: content} = record, image_handling)
      when is_binary(id) and is_binary(content) and content != "" do
    with {:ok, extension} <- extension(record),
         {:ok, mode} <- image_mode(extension, image_handling),
         {:ok, bytes} <- decode(content, encoding(record)),
         {:ok, markdown} <- convert(bytes, extension, mode) do
      {:ok,
       %{
         content: markdown,
         name: markdown_name(record.name),
         mime_type: "text/markdown",
         source: source_metadata(record)
       }}
    end
  end

  def to_markdown(_record, _image_handling), do: {:error, :materialized_file_required}

  defp extension(%Record{name: name, mime_type: mime_type}) do
    extension = ArtifactType.filename_extension(name)

    selected =
      cond do
        ArtifactType.nonspecific_mime?(mime_type) -> extension
        ArtifactType.compatible_extension?(mime_type, extension) -> extension
        true -> ArtifactType.canonical_extension(mime_type)
      end

    if selected in @input_extensions,
      do: {:ok, selected},
      else: {:error, :unsupported_document_format}
  end

  defp image_mode(".pdf", mode) when mode in [nil, "describe"], do: {:ok, :describe}

  defp image_mode(extension, mode)
       when extension in @office_extensions and mode in [nil, "ignore"],
       do: {:ok, :ignore}

  defp image_mode(extension, nil) when extension in @text_extensions, do: {:ok, :none}
  defp image_mode(_extension, _mode), do: {:error, :unsupported_image_handling}

  defp encoding(%Record{attributes: attrs}) when is_map(attrs),
    do: Map.get(attrs, "encoding", Map.get(attrs, :encoding))

  defp encoding(%Record{}), do: nil

  defp decode(content, "base64") when byte_size(content) > @max_base64_bytes,
    do: {:error, :document_too_large}

  defp decode(content, "base64") do
    case Base.decode64(content) do
      {:ok, bytes} -> check_size(bytes)
      :error -> {:error, :invalid_document_encoding}
    end
  end

  defp decode(content, nil), do: check_size(content)
  defp decode(_content, _encoding), do: {:error, :invalid_document_encoding}

  defp check_size(bytes) when byte_size(bytes) > @max_input_bytes,
    do: {:error, :document_too_large}

  defp check_size(bytes), do: {:ok, bytes}

  defp convert(bytes, extension, mode) do
    suffix = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    root = Path.join(System.tmp_dir!(), "zaq_conversion_" <> suffix)

    case File.mkdir(root) do
      :ok ->
        try do
          convert_in_directory(root, bytes, extension, mode)
        after
          File.rm_rf(root)
        end

      {:error, _reason} ->
        {:error, :document_conversion_failed}
    end
  end

  defp convert_in_directory(root, bytes, extension, mode) do
    input_path = Path.join(root, "document" <> extension)
    opts = conversion_options(root, mode)

    with :ok <- File.chmod(root, 0o700),
         :ok <- File.write(input_path, bytes),
         {:ok, markdown} <- DocumentProcessor.read_as_markdown(input_path, opts) do
      finalize(markdown, mode)
    else
      {:error, :image_description_unavailable} = error -> error
      {:error, _reason} -> {:error, :document_conversion_failed}
    end
  end

  defp conversion_options(root, :describe) do
    [images_dir: Path.join(root, "images"), require_image_descriptions: true]
  end

  defp conversion_options(_root, _mode), do: []

  defp finalize(markdown, _mode) when byte_size(markdown) > @max_markdown_bytes,
    do: {:error, :markdown_too_large}

  defp finalize(markdown, :ignore), do: {:ok, OfficeMarkdown.ignore_images(markdown)}
  defp finalize(markdown, _mode), do: {:ok, markdown}

  defp markdown_name(name) when is_binary(name) do
    stem = name |> String.replace("\\", "/") |> Path.basename() |> Path.rootname()
    if stem in ["", ".", "..", "/"], do: "document.md", else: stem <> ".md"
  end

  defp markdown_name(_name), do: "document.md"

  defp source_metadata(%Record{id: id, name: name, mime_type: mime_type}) do
    %{record_id: id}
    |> maybe_put(:name, name)
    |> maybe_put(:mime_type, mime_type)
  end

  defp maybe_put(fields, key, value) when is_binary(value), do: Map.put(fields, key, value)
  defp maybe_put(fields, _key, _value), do: fields
end
