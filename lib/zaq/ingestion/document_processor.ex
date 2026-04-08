defmodule Zaq.Ingestion.DocumentProcessor do
  @moduledoc """
  Processes documents using layout-aware chunking.

  Handles file reading, structured chunking with `DocumentChunker`,
  embedding generation via `Zaq.Embedding.Client`, and storage using
  the `Zaq.Ingestion.Chunk` Ecto schema.

  Also exposes hybrid search (full-text + vector with RRF fusion),
  similarity search, and token-limited query extraction for the
  answering agent.

  ## Configuration (read from `config :zaq, Zaq.Ingestion`)

    * `:max_context_window` - token limit for query extraction (default `5_000`)
    * `:distance_threshold` - vector distance cutoff (default `0.75`)
    * `:hybrid_search_limit` - max rows per search leg (default `20`)
  """

  import Ecto.Query

  alias Zaq.Agent.TokenEstimator
  alias Zaq.Embedding.Client, as: EmbeddingClient
  alias Zaq.Ingestion.{Chunk, Document, DocumentChunker, Sidecar, SourcePath}
  alias Zaq.Ingestion.Python.Pipeline
  alias Zaq.Ingestion.Python.Steps.{DocxToMd, ImageToText, XlsxToMd}
  alias Zaq.Repo

  require Logger

  @access_denied_message "You don't have access to this chunk."

  @doc """
  Returns the message used to replace chunk content when a user lacks access.
  Referenced in tests and the answering prompt migration.
  """
  def access_denied_message, do: @access_denied_message

  NimbleCSV.define(Zaq.Ingestion.CSVParser, separator: ",", escape: "\"")
  alias Zaq.Ingestion.CSVParser

  @supported_extensions ~w(.md .pdf .docx .xlsx .csv .png .jpg)

  @rrf_k 60

  # ---------------------------------------------------------------------------
  # Config helpers
  # ---------------------------------------------------------------------------

  defp max_context_window do
    Zaq.System.get_llm_config().max_context_window
  end

  defp distance_threshold do
    Zaq.System.get_llm_config().distance_threshold
  end

  defp hybrid_search_limit do
    Application.get_env(:zaq, Zaq.Ingestion, [])
    |> Keyword.get(:hybrid_search_limit, 20)
  end

  defp chunk_processing_concurrency do
    default = System.schedulers_online()

    Application.get_env(:zaq, Zaq.Ingestion, [])
    |> Keyword.get(:chunk_processing_concurrency, default)
    |> normalize_concurrency(default)
  end

  defp hybrid_candidate_limit(limit) when is_integer(limit) and limit > 0 do
    limit
  end

  defp hybrid_candidate_limit(_), do: hybrid_search_limit()

  defp normalize_concurrency(value, _default) when is_integer(value) and value > 0, do: value
  defp normalize_concurrency(_value, default), do: default

  defp chunk_title_module do
    Application.get_env(:zaq, :chunk_title_module, Zaq.Agent.ChunkTitle)
  end

  # ---------------------------------------------------------------------------
  # Ingestion - folder / single file
  # ---------------------------------------------------------------------------

  @doc """
  Processes all supported files in the given folder path.

  Supported formats: `.md`, `.pdf`, `.docx`, `.xlsx`, `.csv`, `.png`, `.jpg`

  ## Examples

      iex> Zaq.Ingestion.DocumentProcessor.process_folder("docs/")
      {:ok, %{processed: 5, failed: 0}}
  """
  def process_folder(folder_path) do
    results =
      folder_path
      |> Path.join("*")
      |> Path.wildcard()
      |> Stream.filter(&supported_file?/1)
      |> Enum.reduce(%{processed: 0, failed: 0, total: 0}, fn file_path, acc ->
        case process_single_file(file_path) do
          {:ok, _} -> %{acc | processed: acc.processed + 1, total: acc.total + 1}
          {:error, _} -> %{acc | failed: acc.failed + 1, total: acc.total + 1}
        end
      end)

    Logger.info(
      "Processed #{results.total} files from #{folder_path} (ok=#{results.processed}, failed=#{results.failed})"
    )

    {:ok, %{processed: results.processed, failed: results.failed}}
  end

  defp supported_file?(file_path) do
    Path.extname(file_path) in @supported_extensions
  end

  @doc """
  Processes a single file: converts to markdown if needed, then reads ->
  upserts document -> chunks -> embeds -> stores.

  Supported formats: `.md`, `.pdf`, `.docx`, `.xlsx`, `.csv`, `.png`, `.jpg`
  """
  def process_single_file(file_path) do
    case process_single_file_with_report(file_path) do
      {:ok, document, %{failed_chunks: 0}} ->
        {:ok, document}

      {:ok, _document, %{failed_chunks: failed_chunks}} ->
        {:error, "#{failed_chunks} chunks failed to store"}

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Prepares a file for chunk ingestion without generating embeddings.

  Returns `{ :ok, document, indexed_chunk_payloads }` where payloads are
  `{chunk_payload_map, chunk_index}` tuples.
  """
  def prepare_file_chunks(file_path) do
    Logger.info("Preparing file chunks: #{file_path}")

    with {:ok, content} <- read_as_markdown(file_path),
         {:ok, source} <- extract_source(content, file_path),
         {:ok, sidecar_source} <- extract_sidecar_source(file_path),
         {:ok, document} <-
           store_document(content, source, Sidecar.source_metadata(sidecar_source)),
         :ok <- maybe_store_sidecar_document(content, source, sidecar_source) do
      sections = DocumentChunker.parse_layout(content, format: :markdown)
      chunks = DocumentChunker.chunk_sections(sections)

      indexed_payloads =
        chunks
        |> Enum.with_index(1)
        |> Enum.map(fn {chunk, index} -> {chunk_to_payload(chunk), index} end)

      {:ok, document, indexed_payloads}
    else
      {:error, reason} = error ->
        Logger.error("Failed to prepare chunks for #{file_path}: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Processes a single file and returns an ingestion report with chunk-level progress.
  """
  def process_single_file_with_report(file_path, opts \\ []) do
    Logger.info("Processing file: #{file_path}")

    with {:ok, content} <- read_as_markdown(file_path),
         {:ok, source} <- extract_source(content, file_path),
         {:ok, sidecar_source} <- extract_sidecar_source(file_path),
         {:ok, document} <-
           store_document(content, source, Sidecar.source_metadata(sidecar_source)),
         :ok <- maybe_store_sidecar_document(content, source, sidecar_source),
         {:ok, report} <- process_and_store_chunks_report(content, document.id, opts) do
      Logger.info("Successfully processed: #{source}")
      {:ok, document, report}
    else
      {:error, reason} = error ->
        Logger.error("Failed to process #{file_path}: #{inspect(reason)}")
        error
    end
  end

  # Strips bytes that are not part of a valid UTF-8 sequence.
  # Needed when ingesting files produced by external tools (e.g. the Python
  # PDF pipeline) that may emit Latin-1 or other non-UTF-8 encodings.
  defp sanitize_utf8(binary), do: sanitize_utf8(binary, [])

  defp sanitize_utf8(<<>>, acc), do: IO.iodata_to_binary(:lists.reverse(acc))
  defp sanitize_utf8(<<c::utf8, rest::binary>>, acc), do: sanitize_utf8(rest, [<<c::utf8>> | acc])
  defp sanitize_utf8(<<_::8, rest::binary>>, acc), do: sanitize_utf8(rest, acc)

  # Reads a file and returns its content as a markdown string,
  # converting non-markdown formats as needed.
  defp read_as_markdown(file_path) do
    case Path.extname(file_path) |> String.downcase() do
      ".pdf" ->
        md_path = Path.rootname(file_path) <> ".md"
        read_sidecar_or_convert(md_path, "PDF", fn -> convert_pdf(file_path, md_path) end)

      ".docx" ->
        md_path = Path.rootname(file_path) <> ".md"
        read_sidecar_or_convert(md_path, "DOCX", fn -> convert_docx(file_path, md_path) end)

      ".xlsx" ->
        md_path = Path.rootname(file_path) <> ".md"
        read_sidecar_or_convert(md_path, "XLSX", fn -> convert_xlsx(file_path, md_path) end)

      ext when ext in [".png", ".jpg"] ->
        md_path = Path.rootname(file_path) <> ".md"
        read_sidecar_or_convert(md_path, "image", fn -> convert_image(file_path, md_path) end)

      ".csv" ->
        convert_csv(file_path)

      _ ->
        with {:ok, raw} <- File.read(file_path) do
          {:ok, sanitize_utf8(raw)}
        end
    end
  end

  defp convert_csv(file_path) do
    with {:ok, raw} <- File.read(file_path) do
      rows = CSVParser.parse_string(sanitize_utf8(raw), skip_headers: false)
      {:ok, rows_to_markdown_table(rows)}
    end
  end

  defp convert_pdf(file_path, md_path) do
    with {:ok, _} <- Pipeline.run(file_path),
         {:ok, raw} <- File.read(md_path) do
      Logger.info("[DocumentProcessor] PDF converted to markdown: #{md_path}")
      {:ok, sanitize_utf8(raw)}
    end
  end

  defp convert_docx(file_path, md_path) do
    with {:ok, _} <- DocxToMd.run(file_path, md_path),
         {:ok, raw} <- File.read(md_path) do
      Logger.info("[DocumentProcessor] DOCX converted to markdown: #{md_path}")
      {:ok, sanitize_utf8(raw)}
    end
  end

  defp convert_xlsx(file_path, md_path) do
    with {:ok, _} <- XlsxToMd.run(file_path, md_path),
         {:ok, raw} <- File.read(md_path) do
      Logger.info("[DocumentProcessor] XLSX converted to markdown: #{md_path}")
      {:ok, sanitize_utf8(raw)}
    end
  end

  defp convert_image(file_path, md_path) do
    with {:ok, markdown} <- read_image_as_markdown(file_path),
         :ok <- File.write(md_path, markdown) do
      Logger.info("[DocumentProcessor] Image converted to markdown: #{md_path}")
      {:ok, markdown}
    end
  end

  defp read_sidecar_or_convert(md_path, label, convert_fn) do
    if File.exists?(md_path) do
      Logger.info("[DocumentProcessor] Using existing sidecar for #{label}: #{md_path}")
      with {:ok, raw} <- File.read(md_path), do: {:ok, sanitize_utf8(raw)}
    else
      convert_fn.()
    end
  end

  defp read_image_as_markdown(file_path) do
    output_json = image_description_output_path(file_path)

    try do
      with {:ok, opts} <- image_to_text_opts(),
           {:ok, _} <- image_to_text_step().run_single(file_path, output_json, opts),
           {:ok, raw_json} <- File.read(output_json),
           {:ok, description} <- extract_image_description(raw_json, file_path) do
        image_name = Path.basename(file_path)
        markdown = build_image_markdown(image_name, description)

        {:ok, sanitize_utf8(markdown)}
      end
    after
      _ = File.rm(output_json)
    end
  end

  defp image_description_output_path(file_path) do
    stem =
      file_path
      |> Path.basename(Path.extname(file_path))
      |> String.replace(~r/\s+/u, "_")

    Path.join(
      System.tmp_dir!(),
      "zaq_image_to_text_#{stem}_#{System.unique_integer([:positive])}.json"
    )
  end

  defp image_to_text_opts do
    cfg = Zaq.System.get_image_to_text_config()

    if is_binary(cfg.api_key) and cfg.api_key != "" do
      opts =
        [api_key: cfg.api_key]
        |> maybe_put(:endpoint, cfg.endpoint)
        |> maybe_put(:model, cfg.model)

      {:ok, opts}
    else
      {:error,
       "Image to text is not configured; set it in System settings to enable PNG/JPG ingestion"}
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, ""), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp image_to_text_step do
    Application.get_env(:zaq, :image_to_text_step_module, ImageToText)
  end

  defp extract_image_description(raw_json, file_path) do
    image_name = Path.basename(file_path)

    with {:ok, decoded} <- Jason.decode(raw_json),
         {:ok, description} <- pick_image_description(decoded, image_name),
         :ok <- validate_image_description(description, image_name) do
      {:ok, description}
    end
  end

  defp pick_image_description(%{} = payload, image_name) do
    description =
      Map.get(payload, image_name) ||
        Map.get(payload, String.downcase(image_name)) ||
        single_payload_value(payload)

    {:ok, description}
  end

  defp pick_image_description(_payload, image_name) do
    {:error, "Image-to-text output missing description for #{image_name}"}
  end

  defp single_payload_value(payload) do
    case Map.values(payload) do
      [single] -> single
      _ -> nil
    end
  end

  defp validate_image_description(description, image_name)
       when not is_binary(description) or description == "" do
    {:error, "Image-to-text output missing description for #{image_name}"}
  end

  defp validate_image_description(description, image_name) do
    trimmed_description = String.trim(description)

    cond do
      trimmed_description == "" ->
        {:error, "Image-to-text output missing description for #{image_name}"}

      String.starts_with?(trimmed_description, "ERROR:") ->
        {:error, trimmed_description}

      true ->
        :ok
    end
  end

  defp build_image_markdown(image_name, description) do
    quoted_description =
      description
      |> String.trim()
      |> String.split("\n")
      |> Enum.map_join("\n", fn
        "" -> ">"
        line -> "> #{line}"
      end)

    "> **[Image: #{image_name}]**\n#{quoted_description}\n"
  end

  defp rows_to_markdown_table([]), do: ""

  defp rows_to_markdown_table([header | rest]) do
    header_row = "| " <> Enum.map_join(header, " | ", &to_string/1) <> " |"
    separator = "|" <> Enum.map_join(header, "|", fn _ -> " --- " end) <> "|"

    data_rows =
      Enum.map(rest, fn row -> "| " <> Enum.map_join(row, " | ", &to_string/1) <> " |" end)

    Enum.join([header_row, separator | data_rows], "\n")
  end

  @doc """
  Extracts the source as a volume-prefixed relative path.
  When volumes are configured, returns "<volume_name>/<relative_path_within_volume>".
  In legacy single-volume mode, returns the path relative to `base_path`.
  Falls back to basename if the path is not under any known root.

  Example: "/zaq/volumes/docs/guide.md" => "docs/guide.md"
  """
  def extract_source(_content, file_path) do
    SourcePath.absolute_to_source(file_path)
  end

  defp extract_sidecar_source(file_path) do
    case Sidecar.sidecar_path_for(file_path) do
      nil -> {:ok, nil}
      path -> extract_source("", path)
    end
  end

  defp maybe_store_sidecar_document(_content, _source, nil), do: :ok

  defp maybe_store_sidecar_document(content, source, sidecar_source) do
    attrs = %{
      source: sidecar_source,
      content: content,
      content_type: "markdown",
      metadata: Sidecar.sidecar_metadata(source)
    }

    case Document.upsert(attrs) do
      {:ok, _document} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Upserts a `Zaq.Ingestion.Document` record.
  """
  def store_document(content, source, metadata \\ %{}) do
    attrs = %{content: content, source: source, metadata: metadata}

    case Document.upsert(attrs) do
      {:ok, document} ->
        Logger.info("Document stored with ID: #{document.id}, source: #{source}")
        {:ok, document}

      {:error, changeset} ->
        Logger.error("Failed to store document: #{inspect(changeset)}")
        {:error, changeset}
    end
  end

  @doc """
  Chunks the content using `DocumentChunker`, generates embeddings,
  and stores each chunk via the `Chunk` Ecto schema.
  """
  def process_and_store_chunks(content, document_id) do
    case process_and_store_chunks_report(content, document_id, reset_chunks: true) do
      {:ok, %{results: results, failed_chunks: 0}} ->
        {:ok, results}

      {:ok, %{results: results, failed_chunks: failed}} ->
        Logger.error("Failed to store #{failed} out of #{length(results)} chunks")
        first_error = Enum.find(results, &match?({:error, _}, &1))
        Logger.error("First error example: #{inspect(first_error)}")
        {:error, "#{failed} chunks failed to store"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Chunks `content`, generates embeddings, and persists them for `document_id`.

  Returns `{:ok, report}` on success or `{:error, reason}` on failure.

  ## Options

    * `:reset_chunks` - delete existing chunks before inserting (default `true`).
    * `:retry_chunk_indices` - list of chunk indices to re-process without resetting all chunks.
  """
  def process_and_store_chunks_report(content, document_id, opts \\ []) do
    reset_chunks = Keyword.get(opts, :reset_chunks, true)
    retry_chunk_indices = Keyword.get(opts, :retry_chunk_indices)

    if reset_chunks do
      Chunk.delete_by_document(document_id)
    end

    sections = DocumentChunker.parse_layout(content, format: :markdown)
    chunks = DocumentChunker.chunk_sections(sections)

    Logger.info("Created #{length(chunks)} layout-aware chunks for document_id: #{document_id}")

    selected_chunks = select_chunks(chunks, retry_chunk_indices)

    results =
      selected_chunks
      |> Task.async_stream(
        fn {chunk, index} ->
          maybe_delete_chunk_before_store(reset_chunks, document_id, index)
          {index, store_chunk_with_metadata(chunk, document_id, index)}
        end,
        timeout: :infinity,
        max_concurrency: chunk_processing_concurrency(),
        ordered: false
      )
      |> Enum.map(fn
        {:ok, result} -> result
        {:exit, reason} -> {:error, reason}
      end)

    failed_chunk_indices =
      results
      |> Enum.flat_map(fn
        {index, {:error, _}} -> [index]
        _ -> []
      end)

    normalized_results =
      results
      |> Enum.map(fn
        {index, result} when is_integer(index) -> result
        {:error, reason} -> {:error, reason}
      end)

    case Enum.find(normalized_results, &structural_error?/1) do
      nil ->
        ingested_chunks = Chunk.count_by_document(document_id)

        {:ok,
         %{
           results: normalized_results,
           total_chunks: length(chunks),
           ingested_chunks: ingested_chunks,
           failed_chunks: length(failed_chunk_indices),
           failed_chunk_indices: failed_chunk_indices
         }}

      structural_error ->
        Logger.error("Structural error while storing chunks: #{inspect(structural_error)}")
        {:error, "Structural chunk processing error: #{inspect(structural_error)}"}
    end
  end

  defp select_chunks(chunks, retry_chunk_indices) when is_list(retry_chunk_indices) do
    retry_set = MapSet.new(retry_chunk_indices)

    chunks
    |> Enum.with_index(1)
    |> Enum.filter(fn {_chunk, index} -> MapSet.member?(retry_set, index) end)
  end

  defp select_chunks(chunks, _retry_chunk_indices), do: Enum.with_index(chunks, 1)

  defp maybe_delete_chunk_before_store(true, _document_id, _index), do: :ok

  defp maybe_delete_chunk_before_store(false, document_id, index) do
    Chunk.delete_by_document_and_index(document_id, index)
    :ok
  end

  defp chunk_to_payload(%DocumentChunker.Chunk{} = chunk) do
    %{
      "id" => chunk.id,
      "section_id" => chunk.section_id,
      "content" => chunk.content,
      "section_path" => chunk.section_path,
      "tokens" => chunk.tokens,
      "metadata" => chunk.metadata
    }
  end

  defp structural_error?({:error, :dimension_mismatch}), do: true
  defp structural_error?({:error, %DBConnection.ConnectionError{}}), do: true
  defp structural_error?({:error, %Postgrex.Error{}}), do: true
  defp structural_error?(_), do: false

  @doc """
  Stores a single chunk: generates a descriptive title via LLM,
  embeds the content, validates dimension, and inserts via Ecto.
  """
  def store_chunk_with_metadata(%DocumentChunker.Chunk{} = chunk, document_id, index) do
    chunk_with_title = generate_chunk_title(chunk)

    case EmbeddingClient.embed(chunk_with_title.content) do
      {:ok, embedding} ->
        expected_dim = EmbeddingClient.dimension()

        if length(embedding) != expected_dim do
          Logger.error(
            "Embedding dimension mismatch: expected #{expected_dim}, got #{length(embedding)}"
          )

          {:error, :dimension_mismatch}
        else
          insert_chunk(chunk_with_title, document_id, index, embedding)
        end

      {:error, reason} ->
        Logger.error("Failed to generate embedding for chunk #{index}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Chunk insertion (Ecto)
  # ---------------------------------------------------------------------------

  defp insert_chunk(%DocumentChunker.Chunk{} = chunk, document_id, index, embedding) do
    attrs = %{
      document_id: document_id,
      content: chunk.content,
      chunk_index: index,
      section_path: chunk.section_path,
      metadata: build_metadata(chunk, document_id, index),
      embedding: Pgvector.HalfVector.new(embedding)
    }

    %Chunk{}
    |> Chunk.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, record} ->
        {:ok, record}

      {:error, changeset} ->
        Logger.error("Failed to insert chunk #{index}: #{inspect(changeset)}")
        {:error, changeset}
    end
  end

  @doc """
  Builds metadata map from chunk information.
  """
  def build_metadata(%DocumentChunker.Chunk{} = chunk, document_id, index) do
    section_type = metadata_field(chunk.metadata, :section_type)

    base = %{
      document_id: document_id,
      chunk_index: index,
      section_id: chunk.section_id,
      section_path: chunk.section_path,
      section_type: section_type,
      section_level: metadata_field(chunk.metadata, :section_level),
      position: metadata_field(chunk.metadata, :position),
      tokens: chunk.tokens
    }

    case section_type do
      value when value in [:figure, "figure"] ->
        figure_title = List.last(chunk.section_path) || ""
        Map.put(base, :figure_title, figure_title)

      _ ->
        base
    end
  end

  defp metadata_field(metadata, key) when is_map(metadata) do
    Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key))
  end

  defp metadata_field(_metadata, _key), do: nil

  # ---------------------------------------------------------------------------
  # Query extraction (token-limited context for answering agent)
  # ---------------------------------------------------------------------------

  @doc """
  Extracts token-limited chunks for a given query.
  Groups by document_id and section_path, sorted by vector distance.

  Returns a list of maps with `"content"`, `"source"`, and `"distance"`.

  ## Options

    * `:person_id` - ID of the requesting person; when set, only documents
      the person (or their teams) can access are returned.
    * `:team_ids` - list of team IDs the person belongs to (default `[]`).
    * `:skip_permissions` - when `true`, bypasses all permission filtering.
      Intended for internal/admin queries only (default `false`).
  """
  @spec query_extraction(String.t(), keyword()) :: {:ok, list(map())} | {:error, term()}
  def query_extraction(query, access_opts \\ []) do
    person_id = Keyword.get(access_opts, :person_id)
    team_ids = Keyword.get(access_opts, :team_ids, [])
    skip_permissions = Keyword.get(access_opts, :skip_permissions, false)

    with {:ok, ss} <- similarity_search_group_by(query),
         sections = build_query_sections(ss),
         {:ok, data} <- fetch_sections_with_source(sections) do
      filtered = apply_permission_filter(data, skip_permissions, person_id, team_ids)
      {:ok, limit_to_context_window(filtered)}
    end
  end

  defp build_query_sections(ss) do
    ss
    |> Enum.flat_map(fn {doc_id, paths} ->
      Enum.flat_map(paths, fn
        {_path, []} -> []
        {path, [first | _]} -> [{doc_id, path, first.vector_distance}]
      end)
    end)
    |> List.keysort(2)
    |> Enum.uniq_by(fn {doc_id, path, _} -> {doc_id, path} end)
  end

  defp limit_to_context_window(data) do
    {answer, _} =
      Enum.reduce_while(data, {[], 0}, fn chunk, {acc, acc_tokens} ->
        output_tokens = chunk |> Jason.encode!() |> TokenEstimator.estimate()

        if acc_tokens + output_tokens < max_context_window() do
          {:cont, {[chunk | acc], acc_tokens + output_tokens}}
        else
          {:halt, {acc, acc_tokens}}
        end
      end)

    Enum.reverse(answer)
  end

  defp similarity_search_group_by(query_text) do
    with {:ok, embedding} <- EmbeddingClient.embed(query_text) do
      embedding_vector = Pgvector.HalfVector.new(embedding)
      threshold = distance_threshold()

      results =
        Chunk
        |> join(:inner, [c], d in Document, on: c.document_id == d.id)
        |> where([c, _d], fragment("? <-> ? < ?", c.embedding, ^embedding_vector, ^threshold))
        |> order_by([c, _d], asc: fragment("? <-> ?", c.embedding, ^embedding_vector))
        |> select([c, _d], %{
          document_id: c.document_id,
          section_path: c.section_path,
          vector_distance: fragment("? <-> ?", c.embedding, ^embedding_vector)
        })
        |> Repo.all()

      grouped =
        results
        |> Enum.group_by(& &1.document_id)
        |> Map.new(fn {doc_id, items} ->
          {doc_id, Enum.group_by(items, & &1.section_path)}
        end)

      {:ok, grouped}
    end
  end

  defp fetch_sections_with_source([]), do: {:ok, []}

  defp fetch_sections_with_source(sections) do
    distance_map = Map.new(sections, fn {doc_id, path, dist} -> {{doc_id, path}, dist} end)

    or_filter =
      Enum.reduce(sections, dynamic(false), fn {doc_id, path, _dist}, acc ->
        dynamic([c], ^acc or (c.document_id == ^doc_id and c.section_path == ^path))
      end)

    results =
      Chunk
      |> join(:inner, [c], d in Document, on: c.document_id == d.id)
      |> where([c, _d], ^or_filter)
      |> select([c, d], %{
        content: c.content,
        source: d.source,
        document_id: c.document_id,
        section_path: c.section_path
      })
      |> Repo.all()
      |> Enum.map(fn r ->
        dist = distance_map[{r.document_id, r.section_path}]

        %{
          "content" => r.content,
          "source" => r.source,
          "distance" => dist,
          "document_id" => r.document_id
        }
      end)
      |> Enum.sort_by(& &1["distance"])

    {:ok, results}
  end

  # ---------------------------------------------------------------------------
  # Hybrid search (full-text + vector with RRF fusion)
  # ---------------------------------------------------------------------------

  @doc """
  Performs hybrid search combining full-text search and vector similarity
  using Reciprocal Rank Fusion (RRF).

  Returns `{:ok, results}` where each result is a map with keys:
  `:chunk`, `:source`, `:rrf_score`, `:text_rank`, `:vector_distance`.
  """
  def hybrid_search(query_text, limit \\ nil) do
    limit = limit || hybrid_search_limit()
    candidate_limit = hybrid_candidate_limit(limit)

    with {:ok, embedding} <- EmbeddingClient.embed(query_text) do
      embedding_vector = Pgvector.HalfVector.new(embedding)
      k = @rrf_k

      results =
        Chunk
        |> join(:inner, [c], d in Document, on: c.document_id == d.id)
        |> where(
          [c, _d],
          fragment(
            """
            c0.id IN (
              SELECT id FROM (
                SELECT id,
                       ROW_NUMBER() OVER (
                         ORDER BY ts_rank(to_tsvector('english', content),
                                          plainto_tsquery('english', ?)) DESC
                       ) AS rn
                FROM chunks
                WHERE to_tsvector('english', content) @@ plainto_tsquery('english', ?)
                LIMIT ?
              ) ts
              UNION
              SELECT id FROM (SELECT id FROM chunks ORDER BY embedding <-> ? LIMIT ?) vs
            )
            """,
            ^query_text,
            ^query_text,
            ^candidate_limit,
            ^embedding_vector,
            ^candidate_limit
          )
        )
        |> select([c, d], %{
          chunk: c,
          source: d.source,
          rrf_score:
            fragment(
              """
              COALESCE(1.0 / (? + (
                SELECT rn FROM (
                  SELECT id,
                         ROW_NUMBER() OVER (
                           ORDER BY ts_rank(to_tsvector('english', content),
                                            plainto_tsquery('english', ?)) DESC
                         ) AS rn
                  FROM chunks
                  WHERE to_tsvector('english', content) @@ plainto_tsquery('english', ?)
                  LIMIT ?
                ) ts WHERE ts.id = c0.id
              )), 0)
              +
              COALESCE(1.0 / (? + (
                SELECT rn FROM (
                  SELECT id,
                         ROW_NUMBER() OVER (ORDER BY embedding <-> ?) AS rn
                  FROM chunks
                  ORDER BY embedding <-> ?
                  LIMIT ?
                ) vs WHERE vs.id = c0.id
              )), 0)
              """,
              ^k,
              ^query_text,
              ^query_text,
              ^candidate_limit,
              ^k,
              ^embedding_vector,
              ^embedding_vector,
              ^candidate_limit
            ),
          text_rank:
            fragment(
              "ts_rank(to_tsvector('english', ?), plainto_tsquery('english', ?))",
              c.content,
              ^query_text
            ),
          vector_distance: fragment("? <-> ?", c.embedding, ^embedding_vector)
        })
        |> order_by(
          [c, _d],
          desc:
            fragment(
              """
              COALESCE(1.0 / (? + (
                SELECT rn FROM (
                  SELECT id,
                         ROW_NUMBER() OVER (
                           ORDER BY ts_rank(to_tsvector('english', content),
                                            plainto_tsquery('english', ?)) DESC
                         ) AS rn
                  FROM chunks
                  WHERE to_tsvector('english', content) @@ plainto_tsquery('english', ?)
                  LIMIT ?
                ) ts WHERE ts.id = c0.id
              )), 0)
              +
              COALESCE(1.0 / (? + (
                SELECT rn FROM (
                  SELECT id,
                         ROW_NUMBER() OVER (ORDER BY embedding <-> ?) AS rn
                  FROM chunks
                  ORDER BY embedding <-> ?
                  LIMIT ?
                ) vs WHERE vs.id = c0.id
              )), 0)
              """,
              ^k,
              ^query_text,
              ^query_text,
              ^candidate_limit,
              ^k,
              ^embedding_vector,
              ^embedding_vector,
              ^candidate_limit
            )
        )
        |> limit(^limit)
        |> Repo.all()

      {:ok, results}
    end
  end

  # ---------------------------------------------------------------------------
  # Similarity search (vector only)
  # ---------------------------------------------------------------------------

  @doc """
  Performs vector similarity search.
  Returns chunks within `distance_threshold` ordered by distance,
  with the document source included.
  """
  def similarity_search(query_text, limit \\ 5) do
    with {:ok, embedding} <- EmbeddingClient.embed(query_text) do
      embedding_vector = Pgvector.HalfVector.new(embedding)
      threshold = distance_threshold()

      results =
        Chunk
        |> join(:inner, [c], d in Document, on: c.document_id == d.id)
        |> where(
          [c, _d],
          fragment("? <-> ? < ?", c.embedding, ^embedding_vector, ^threshold)
        )
        |> order_by([c, _d], fragment("? <-> ?", c.embedding, ^embedding_vector))
        |> limit(^limit)
        |> select([c, d], %{
          chunk: c,
          source: d.source,
          vector_distance: fragment("? <-> ?", c.embedding, ^embedding_vector)
        })
        |> Repo.all()

      {:ok, results}
    end
  end

  # ---------------------------------------------------------------------------
  # Similarity search count (hybrid union count)
  # ---------------------------------------------------------------------------

  @doc """
  Returns the count of unique chunks matching via hybrid search
  (text + vector union).
  """
  def similarity_search_count(query_text) do
    with {:ok, embedding} <- EmbeddingClient.embed(query_text) do
      embedding_vector = Pgvector.HalfVector.new(embedding)

      text_ids =
        from(c in Chunk,
          where:
            fragment(
              "to_tsvector('english', ?) @@ plainto_tsquery('english', ?)",
              c.content,
              ^query_text
            ),
          select: %{id: c.id},
          limit: 20
        )

      vector_ids =
        from(c in Chunk,
          order_by: fragment("? <-> ?", c.embedding, ^embedding_vector),
          select: %{id: c.id},
          limit: 20
        )

      combined =
        from(
          c in subquery(union_all(text_ids, ^vector_ids)),
          select: count(c.id, :distinct)
        )

      {:ok, Repo.one(combined)}
    end
  end

  # ---------------------------------------------------------------------------
  # Permission filter
  # ---------------------------------------------------------------------------

  defp apply_permission_filter(data, true, _person_id, _team_ids), do: data
  defp apply_permission_filter(data, _skip, nil, _team_ids), do: data

  defp apply_permission_filter(data, false, person_id, team_ids) do
    doc_ids = data |> Enum.map(& &1["document_id"]) |> Enum.uniq()

    permitted =
      doc_ids
      |> Enum.chunk_every(500)
      |> Enum.flat_map(&Zaq.Ingestion.list_permitted_document_ids(person_id, team_ids, &1))

    permitted_set = MapSet.new(permitted)

    Enum.map(data, fn chunk ->
      if MapSet.member?(permitted_set, chunk["document_id"]) do
        chunk
      else
        Map.put(chunk, "content", @access_denied_message)
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Chunk title generation
  # ---------------------------------------------------------------------------

  defp generate_chunk_title(%DocumentChunker.Chunk{} = chunk) do
    # Use ChunkTitle for all chunk types (TitleAgent / Ollama dropped)
    generate_descriptive_title(chunk)
  end

  defp generate_descriptive_title(%DocumentChunker.Chunk{} = chunk) do
    content_for_analysis = strip_existing_heading(chunk.content)

    case chunk_title_module().ask(content_for_analysis, []) do
      {:ok, generated_title} when generated_title != "" ->
        Logger.info("Generated title for chunk: #{generated_title}")

        updated_content = replace_heading_with_title(chunk.content, generated_title)
        updated_path = update_section_path_with_title(chunk.section_path, generated_title)

        %{chunk | content: updated_content, section_path: updated_path}

      {:ok, ""} ->
        Logger.warning("ChunkTitle returned empty, keeping original")
        chunk

      {:error, reason} ->
        Logger.warning("Failed to generate title, keeping original: #{inspect(reason)}")
        chunk
    end
  end

  # ---------------------------------------------------------------------------
  # Heading / title helpers
  # ---------------------------------------------------------------------------

  defp strip_existing_heading(content) do
    content
    |> String.replace(~r/^\#{1,6}\s*\*{0,2}[^*\n]+\*{0,2}\s*\n+/, "")
    |> String.trim()
  end

  defp replace_heading_with_title(content, new_title) do
    if String.match?(content, ~r/^\#{1,6}\s*\*{0,2}[^*\n]+\*{0,2}\s*\n/) do
      String.replace(
        content,
        ~r/^\#{1,6}\s*\*{0,2}[^*\n]+\*{0,2}\s*\n+/,
        "## **#{new_title}**\n\n"
      )
    else
      "## **#{new_title}**\n\n" <> content
    end
  end

  defp update_section_path_with_title(section_path, new_title) when is_list(section_path) do
    case section_path do
      [] -> [new_title]
      path -> List.replace_at(path, -1, new_title)
    end
  end

  defp update_section_path_with_title(_, new_title), do: [new_title]
end
