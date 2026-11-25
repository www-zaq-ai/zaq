defmodule Zaq.Ingestion.DocumentConversion do
  @moduledoc """
  Owns file-to-Markdown conversion for ingestion and standalone callers.

  A Record supplies the downloaded representation, not permission to use its
  source identity elsewhere. Standalone conversion never redeems handles or
  opens user-supplied paths. Ingestion can also convert its trusted local files.
  """

  alias Zaq.Contracts.Record
  alias Zaq.Ingestion.{FTSBackend, ImageMarkdown, OfficeMarkdown, RecordSource}
  alias Zaq.Ingestion.Python.Pipeline
  alias Zaq.Ingestion.Python.Steps.{DocxToMd, PptxToMd, XlsxToMd}
  alias Zaq.Ingestion.TemporaryMaterializationStore

  NimbleCSV.define(Zaq.Ingestion.CSVParser, separator: ",", escape: "\"")
  alias Zaq.Ingestion.CSVParser

  @office_extensions ~w(.docx .pptx .xlsx)
  @text_extensions ~w(.csv .md .markdown)
  @input_extensions [".pdf" | @text_extensions ++ @office_extensions]
  @max_input_bytes 20 * 1024 * 1024
  @max_markdown_bytes 5 * 1024 * 1024

  @doc """
  Returns Markdown content, a suggested filename and descriptive source metadata.

  `image_handling` defaults to `describe` for PDF and `ignore` for Office. A
  caller-supplied mode must be supported by the downloaded format.
  """
  @spec to_markdown(Record.t(), String.t() | nil) :: {:ok, map()} | {:error, atom()}
  def to_markdown(record, image_handling \\ nil) do
    with {:ok, input} <- prepare(record, image_handling, %{}), do: convert_prepared(input)
  end

  @doc """
  Prepares private converter input before dispatching to the Ingestion role.

  Decoding inherits the parent Action's local audit context. Decoded bytes are
  private event input, never a workflow result.
  """
  @spec prepare(Record.t(), String.t() | nil, map()) :: {:ok, map()} | {:error, atom()}
  def prepare(%Record{id: id, kind: :file, content: content} = record, image_handling, context)
      when is_binary(id) and is_binary(content) and content != "" do
    extension = RecordSource.download_extension(record, record)

    with :ok <- supported_extension(extension),
         {:ok, mode} <- image_mode(extension, image_handling),
         {:ok, bytes} <-
           RecordSource.download_bytes(record, {:conversion, @max_input_bytes}, context) do
      {:ok,
       %{bytes: bytes, extension: extension, image_mode: mode, source: source_metadata(record)}}
    end
  end

  def prepare(_record, _image_handling, _context), do: {:error, :materialized_file_required}

  defp supported_extension(extension) when extension in @input_extensions, do: :ok
  defp supported_extension(_extension), do: {:error, :unsupported_document_format}

  defp image_mode(".pdf", mode) when mode in [nil, "describe"], do: {:ok, :describe}

  defp image_mode(extension, mode)
       when extension in @office_extensions and mode in [nil, "ignore"],
       do: {:ok, :ignore}

  defp image_mode(extension, nil) when extension in @text_extensions, do: {:ok, :none}
  defp image_mode(_extension, _mode), do: {:error, :unsupported_image_handling}

  @doc "Converts private input from `prepare/3` on the Ingestion node."
  @spec convert_prepared(map()) :: {:ok, map()} | {:error, atom()}
  def convert_prepared(%{
        bytes: bytes,
        extension: extension,
        image_mode: mode,
        source: %{record_id: id} = source
      })
      when is_binary(id) and is_binary(bytes) and byte_size(bytes) <= @max_input_bytes and
             extension in @input_extensions do
    record = %Record{id: id, kind: :file}

    result =
      TemporaryMaterializationStore.with_original(record, bytes, extension, fn stored ->
        read_file(stored.absolute_path, conversion_options(stored.root_path, mode))
      end)

    with {:ok, markdown} <- result, {:ok, markdown} <- finalize(markdown, mode) do
      {:ok,
       %{
         content: markdown,
         name: markdown_name(source[:name]),
         mime_type: "text/markdown",
         source: source
       }}
    else
      {:error, reason} = error
      when reason in [:image_description_unavailable, :markdown_too_large] ->
        error

      {:error, _reason} ->
        {:error, :document_conversion_failed}
    end
  end

  def convert_prepared(_input), do: {:error, :document_conversion_failed}

  @doc """
  Converts a trusted local file without indexing it. The caller owns its scratch
  files. Ingestion can report PDF progress, and does not require vision for PDF.
  """
  @spec read_file(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def read_file(path, opts) do
    output = Path.rootname(path) <> ".md"

    case path |> Path.extname() |> String.downcase() do
      ".pdf" ->
        pipeline = Zaq.Config.get(:zaq, :pdf_pipeline_module, Pipeline, opts)

        pipeline_opts =
          Keyword.take(opts, [:on_progress, :images_dir, :require_image_descriptions])

        read_converted(pipeline.run(path, pipeline_opts), output)

      ".docx" ->
        convert_office(path, output, opts, :docx_to_md_module, DocxToMd)

      ".pptx" ->
        convert_office(path, output, opts, :pptx_to_md_module, PptxToMd)

      ".xlsx" ->
        convert_office(path, output, opts, :xlsx_to_md_module, XlsxToMd)

      extension when extension in [".png", ".jpg", ".jpeg"] ->
        ImageMarkdown.convert(path, output, opts)

      ".csv" ->
        with {:ok, text} <- read_text(path) do
          rows = CSVParser.parse_string(text, skip_headers: false)
          {:ok, rows_to_markdown_table(rows)}
        end

      _extension ->
        read_text(path)
    end
  end

  defp convert_office(path, output, opts, config_key, default) do
    converter = Zaq.Config.get(:zaq, config_key, default, opts)
    read_converted(converter.run(path, output), output)
  end

  defp read_converted({:ok, _}, output), do: read_text(output)
  defp read_converted(error, _output), do: error

  defp read_text(path) do
    with {:ok, content} <- File.read(path), do: {:ok, FTSBackend.sanitize_utf8_text(content)}
  end

  defp rows_to_markdown_table([]), do: ""

  defp rows_to_markdown_table([header | rest]) do
    header_row = "| " <> Enum.map_join(header, " | ", &to_string/1) <> " |"
    separator = "|" <> Enum.map_join(header, "|", fn _ -> " --- " end) <> "|"

    data_rows =
      Enum.map(rest, fn row -> "| " <> Enum.map_join(row, " | ", &to_string/1) <> " |" end)

    Enum.join([header_row, separator | data_rows], "\n")
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
