defmodule Zaq.Ingestion.DocumentProcessor do
  @moduledoc """
  Processes documents using layout-aware chunking.

  Takes Markdown from `DocumentConversion` for structured chunking with `DocumentChunker`,
  embedding generation via `Zaq.Embedding.Client`, and storage using
  the `Zaq.Ingestion.Chunk` Ecto schema.

  Exposes BM25+vector hybrid search via parallel `Task.async` with Elixir-side
  RRF fusion, and query extraction with optional caller-owned token budgets.

  ## Configuration (read from `config :zaq, Zaq.Ingestion`)

    * `:max_cosine_distance` - vector distance cutoff (default `0.45`)
    * `:hybrid_search_limit` - max rows per search leg (default `20`)
  """

  import Ecto.Query

  alias Zaq.Agent.TokenEstimator
  alias Zaq.Embedding.Client, as: EmbeddingClient

  alias Zaq.Ingestion.{
    Chunk,
    ChunkLanguages,
    ChunkRefresh,
    Document,
    DocumentAccess,
    DocumentChunker,
    DocumentConversion,
    DocumentIngestionSummary,
    FTSBackend,
    KnowledgeChunks
  }

  alias Zaq.Ingestion.LanguageDetector
  alias Zaq.Repo

  require Logger

  @doc """
  Returns the message used to replace chunk content when a user lacks access.
  Referenced in tests and the answering prompt migration.
  """
  defdelegate access_denied_message(), to: KnowledgeChunks

  @supported_extensions ~w(.md .pdf .docx .pptx .xlsx .csv .png .jpg .jpeg)

  @rrf_k 60

  # ---------------------------------------------------------------------------
  # Config helpers
  # ---------------------------------------------------------------------------

  defp max_cosine_distance do
    Zaq.System.get_retrieval_config().max_cosine_distance
  end

  # Check the stored precision rather than the source floats: a small nonzero
  # provider vector can round entirely to zero on halfvec conversion.
  defp zero_halfvec?(embedding) do
    %Pgvector.HalfVector{data: <<_dimension::16, _reserved::16, values::binary>>} =
      Pgvector.HalfVector.new(embedding)

    not Enum.any?(for(<<value::float-16 <- values>>, do: value), &(&1 != 0.0))
  end

  defp validate_nonzero_embedding(embedding) do
    if zero_halfvec?(embedding), do: {:error, :zero_norm_embedding}, else: :ok
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

  defp chunk_processing_timeout do
    Application.get_env(:zaq, Zaq.Ingestion, [])
    |> Keyword.get(:chunk_processing_timeout, 90_000)
  end

  defp normalize_concurrency(value, _default) when is_integer(value) and value > 0, do: value
  defp normalize_concurrency(_value, default), do: default

  # ---------------------------------------------------------------------------
  # Ingestion - folder / single file
  # ---------------------------------------------------------------------------

  @doc """
  Processes all supported files in the given folder path.

  Supported formats: `.md`, `.pdf`, `.docx`, `.pptx`, `.xlsx`, `.csv`, `.png`, `.jpg`

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

  Supported formats: `.md`, `.pdf`, `.docx`, `.pptx`, `.xlsx`, `.csv`, `.png`, `.jpg`
  """
  def process_single_file(file_path) do
    process_single_file(file_path, [])
  end

  def process_single_file(file_path, opts) do
    case process_single_file_with_report(file_path, opts) do
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

  Converted Markdown is stored on the primary document; any files created while
  converting are temporary materialization artifacts owned by the caller.
  """
  def prepare_file_chunks(file_path, opts \\ []) do
    Logger.info("Preparing file chunks: #{file_path}")
    requested_at = Keyword.get_lazy(opts, :refresh_requested_at, &DateTime.utc_now/0)

    with {:ok, content} <- DocumentConversion.read_file(file_path, opts),
         {:ok, source} <- extract_source(content, file_path, opts),
         {:ok, document} <-
           store_document(
             content,
             source,
             source_metadata(opts),
             document_title(opts),
             requested_at
           ) do
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

  Converted Markdown is stored on the primary document.
  """
  def process_single_file_with_report(file_path, opts \\ []) do
    Logger.info("Processing file: #{file_path}")
    requested_at = Keyword.get_lazy(opts, :refresh_requested_at, &DateTime.utc_now/0)

    with {:ok, content} <- DocumentConversion.read_file(file_path, opts),
         {:ok, source} <- extract_source(content, file_path, opts),
         {:ok, document} <-
           store_document(
             content,
             source,
             source_metadata(opts),
             document_title(opts),
             requested_at
           ),
         {:ok, report} <-
           process_and_store_chunks_report(
             content,
             document.id,
             Keyword.put(opts, :refresh_requested_at, requested_at)
           ) do
      Logger.info("Successfully processed: #{source}")
      {:ok, document, report}
    else
      {:error, reason} = error ->
        Logger.error("Failed to process #{file_path}: #{inspect(reason)}")
        error
    end
  end

  @doc false
  def sanitize_fts_query(text) do
    FTSBackend.impl().sanitize_query(text)
  end

  @doc """
  Extracts the document source for indexing.

  Data-source ingestion must pass `:source_override`; the fallback is only for
  direct processor calls and uses the local artifact basename rather than any
  mounted-volume knowledge.
  """
  def extract_source(content, file_path, opts) do
    case Keyword.get(opts, :source_override) do
      source when is_binary(source) and source != "" -> {:ok, source}
      _ -> extract_source(content, file_path)
    end
  end

  def extract_source(_content, file_path) do
    {:ok, Path.basename(file_path)}
  end

  defp source_metadata(opts) do
    opts
    |> Keyword.get(:document_metadata, %{})
  end

  @doc """
  Upserts a `Zaq.Ingestion.Document` record.
  """
  def store_document(content, source, metadata \\ %{}, title \\ nil) do
    store_document(content, source, metadata, title, DateTime.utc_now())
  end

  defp store_document(content, source, metadata, title, requested_at) do
    attrs =
      %{content: content, source: source, metadata: metadata}
      |> maybe_put_title(title)

    case Document.upsert(attrs, requested_at) do
      {:ok, document} ->
        Logger.info("Document stored with ID: #{document.id}, source: #{source}")
        {:ok, document}

      {:error, changeset} ->
        Logger.error("Failed to store document: #{inspect(changeset)}")
        {:error, changeset}
    end
  end

  defp document_title(opts), do: Keyword.get(opts, :document_title)

  defp maybe_put_title(attrs, title) when is_binary(title) and title != "",
    do: Map.put(attrs, :title, title)

  defp maybe_put_title(attrs, _title), do: attrs

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
    requested_at = Keyword.get(opts, :refresh_requested_at)

    if reset_chunks do
      delete_pipeline_chunks(document_id, requested_at, fn ->
        Chunk.delete_by_document(document_id, invalidate?: false)
      end)
    end

    sections = DocumentChunker.parse_layout(content, format: :markdown)
    chunks = DocumentChunker.chunk_sections(sections)

    Logger.info("Created #{length(chunks)} layout-aware chunks for document_id: #{document_id}")

    selected_chunks = select_chunks(chunks, retry_chunk_indices)

    results =
      selected_chunks
      |> Task.async_stream(
        fn {chunk, index} ->
          maybe_delete_chunk_before_store(reset_chunks, document_id, index, requested_at)
          {index, store_chunk_with_metadata(chunk, document_id, index, requested_at)}
        end,
        timeout: chunk_processing_timeout(),
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
        :ok = DocumentIngestionSummary.refresh_inline(document_id, chunks, results, reset_chunks)

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

  defp maybe_delete_chunk_before_store(true, _document_id, _index, _requested_at), do: :ok

  defp maybe_delete_chunk_before_store(false, document_id, index, requested_at) do
    delete_pipeline_chunks(document_id, requested_at, fn ->
      Chunk.delete_by_document_and_index(document_id, index)
    end)
  end

  defp delete_pipeline_chunks(document_id, requested_at, delete) do
    case ChunkRefresh.pipeline_write(document_id, delete, requested_at) do
      {:ok, {count, _}} when count > 0 -> ChunkLanguages.invalidate()
      _ -> :ok
    end

    :ok
  end

  defp chunk_to_payload(%DocumentChunker.Chunk{} = chunk) do
    %{
      "language" => LanguageDetector.detect(chunk.content),
      "section_id" => chunk.section_id,
      "content" => chunk.content,
      "section_path" => chunk.section_path,
      "tokens" => chunk.tokens,
      "metadata" => chunk.metadata,
      "start_page" => chunk.start_page,
      "end_page" => chunk.end_page,
      "start_line" => chunk.start_line,
      "end_line" => chunk.end_line
    }
  end

  defp structural_error?({:error, :dimension_mismatch}), do: true
  defp structural_error?({:error, :stale_refresh}), do: true
  defp structural_error?({:error, %DBConnection.ConnectionError{}}), do: true
  defp structural_error?({:error, %Postgrex.Error{}}), do: true
  defp structural_error?(_), do: false

  @doc """
  Stores a single chunk: embeds the content, validates dimension, and inserts
  via Ecto.
  """
  def store_chunk_with_metadata(
        %DocumentChunker.Chunk{} = chunk,
        document_id,
        index,
        requested_at \\ nil
      ) do
    # Embed the enriched input; persist only the verbatim content. The
    # fallback stays at this call site — Zaq.Embedding.Client also serves
    # query-time callers that must receive plain text.
    case EmbeddingClient.embed(chunk.embedding_input || chunk.content) do
      {:ok, embedding} ->
        expected_dim = EmbeddingClient.dimension()

        if length(embedding) != expected_dim do
          Logger.error(
            "Embedding dimension mismatch: expected #{expected_dim}, got #{length(embedding)}"
          )

          {:error, :dimension_mismatch}
        else
          insert_pipeline_chunk(chunk, document_id, index, embedding, requested_at)
        end

      {:error, reason} ->
        Logger.error("Failed to generate embedding for chunk #{index}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp insert_pipeline_chunk(chunk, document_id, index, embedding, requested_at) do
    ChunkRefresh.pipeline_write(
      document_id,
      fn ->
        insert_precomputed_chunk(
          document_id,
          index,
          chunk.content,
          chunk.section_path,
          build_metadata(chunk),
          embedding
        )
      end,
      requested_at
    )
    |> case do
      {:ok, {:ok, _chunk} = result} ->
        ChunkLanguages.invalidate()
        result

      {:ok, result} ->
        result

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Inserts a chunk with a dimension-checked vector. The caller owns refresh
  authorization, fencing, and post-commit cache invalidation. The vector must
  remain nonzero at half precision.
  """
  @spec insert_precomputed_chunk(pos_integer(), pos_integer(), String.t(), [String.t()], map(), [
          number()
        ]) ::
          {:ok, Chunk.t()} | {:error, term()}
  def insert_precomputed_chunk(document_id, index, content, section_path, metadata, embedding) do
    with :ok <- validate_nonzero_embedding(embedding) do
      insert_chunk(document_id, index, content, section_path, metadata, embedding)
    end
  end

  # ---------------------------------------------------------------------------
  # Chunk insertion (Ecto)
  # ---------------------------------------------------------------------------

  defp insert_chunk(document_id, index, content, section_path, metadata, embedding) do
    language = LanguageDetector.detect(content)

    search_configuration =
      case FTSBackend.impl() do
        FTSBackend.Native ->
          FTSBackend.Native.configuration_for(language) |> String.split(".") |> List.last()

        # The current ParadeDB index has no language-specific analyzer. Until
        # one is provisioned this is the language-neutral equivalent of simple.
        FTSBackend.ParadeDB ->
          "simple"
      end

    attrs = %{
      document_id: document_id,
      content: content,
      chunk_index: index,
      section_path: section_path,
      metadata:
        metadata
        |> Map.delete(:search_configuration)
        |> Map.put("search_configuration", search_configuration),
      embedding: Pgvector.HalfVector.new(embedding),
      language: language
    }

    %Chunk{}
    |> Chunk.changeset(attrs)
    |> Repo.insert(mode: :savepoint)
  end

  @doc """
  Builds the metadata jsonb for a chunk.

  Holds only what is not already a column on `chunks` (`document_id`,
  `chunk_index` and `section_path` are columns — never mirrored here), plus
  source locators tracing the chunk back to the converter markdown:
  `start`/`end` as `"P<page>|L<line>"` strings. Locator keys are omitted
  entirely when the chunker struct carries no locators (legacy path).
  """
  def build_metadata(%DocumentChunker.Chunk{} = chunk) do
    section_type = metadata_field(chunk.metadata, :section_type)

    base = %{
      section_id: chunk.section_id,
      section_type: section_type,
      section_level: metadata_field(chunk.metadata, :section_level),
      position: metadata_field(chunk.metadata, :position),
      tokens: chunk.tokens
    }

    base = put_locators(base, chunk)

    case section_type do
      value when value in [:figure, "figure"] ->
        figure_title = List.last(chunk.section_path) || ""
        Map.put(base, :figure_title, figure_title)

      _ ->
        base
    end
  end

  defp put_locators(meta, %DocumentChunker.Chunk{} = chunk) do
    meta
    |> put_page_line(:start, chunk.start_page, chunk.start_line)
    |> put_page_line(:end, chunk.end_page, chunk.end_line)
  end

  defp put_page_line(meta, key, page, line) when is_integer(page) and is_integer(line) do
    Map.put(meta, key, "P#{page}|L#{line}")
  end

  defp put_page_line(meta, _key, _page, _line), do: meta

  defp metadata_field(metadata, key) when is_map(metadata) do
    Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key))
  end

  defp metadata_field(_metadata, _key), do: nil

  # ---------------------------------------------------------------------------
  # Query extraction (token-limited context for answering agent)
  # ---------------------------------------------------------------------------

  @doc """
  Extracts token-limited chunks for a given query.
  Ranks direct chunks by fused lexical/vector evidence. Surrounding context is
  available through each accessible chunk's previous/next IDs, not enrichment.

  Returns a list of maps with `"content"`, `"source"`, `"rrf_score"`, and
  `"vector_distance"` and chunk/navigation IDs. Only direct matches are returned;
  measured distance is present only for vector matches.

  ## Options

    * `:person_id` - ID of the requesting person; when set, only documents
      the person (or their teams) can access are returned.
    * `:team_ids` - list of team IDs the person belongs to (default `[]`).
    * `:skip_permissions` - when `true`, bypasses all permission filtering.
      Intended for internal/admin queries only (default `false`).
    * `:token_budget` - optional non-negative token limit supplied by the caller.
      Without it, only the retrieval candidate limits apply; no global LLM limit is read.
  """
  @spec query_extraction(String.t(), keyword()) :: {:ok, list(map())} | {:error, term()}
  def query_extraction(query, access_opts \\ []) do
    source_filter = Keyword.get(access_opts, :source_filter, [])
    language = Keyword.get(access_opts, :language)
    lexical_terms = lexical_input(Keyword.get(access_opts, :lexical_terms), query)
    mode = Keyword.get(access_opts, :search_mode, :hybrid)

    with {:ok, grouped} <- retrieve(query, lexical_terms, source_filter, language, mode) do
      filtered = KnowledgeChunks.hydrate(ranked_matches(grouped, mode), access_opts)

      if Keyword.get(access_opts, :unbounded, false) do
        {:ok, filtered}
      else
        {:ok, limit_to_context_window(filtered, Keyword.get(access_opts, :token_budget))}
      end
    end
  end

  defp ranked_matches(grouped, mode) do
    grouped
    |> Enum.flat_map(fn {_doc_id, paths} -> Enum.flat_map(paths, &elem(&1, 1)) end)
    |> Enum.sort_by(&{match_score(&1, mode), &1.document_id, &1.section_path, &1.chunk_index})
  end

  defp match_score(match, :semantic), do: match.vector_distance
  defp match_score(match, :keyword), do: -match.bm25_score
  defp match_score(match, :hybrid), do: -match.rrf_score

  defp lexical_input(nil, query), do: query

  defp lexical_input(terms, _query) when is_list(terms) do
    terms
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp lexical_input(_invalid, _query), do: []

  defp retrieve(query, _terms, source_filter, language, :semantic) do
    similarity_search_group_by(query, source_filter, language)
  end

  defp retrieve(_query, terms, source_filter, language, :keyword) do
    with {:ok, grouped} <-
           bm25_search_group_by(terms, hybrid_search_limit(), source_filter, language) do
      {:ok,
       Map.new(grouped, fn {doc_id, paths} ->
         {doc_id, mark_lexical_matches(paths)}
       end)}
    end
  end

  defp retrieve(query, lexical_terms, source_filter, language, :hybrid) do
    limit = hybrid_search_limit()

    bm25_task =
      Task.async(fn -> bm25_search_group_by(lexical_terms, limit, source_filter, language) end)

    vector_task = Task.async(fn -> similarity_search_group_by(query, source_filter, language) end)

    with {:ok, bm25} <- Task.await(bm25_task, 30_000),
         {:ok, vector} <- Task.await(vector_task, 30_000) do
      rrf_merge(bm25, vector)
    end
  end

  defp retrieve(_query, _terms, _source_filter, _language, _mode),
    do: {:error, :invalid_search_mode}

  defp mark_lexical_matches(paths) do
    Map.new(paths, fn {path, matches} ->
      {path, Enum.map(matches, &Map.put(&1, :lexical_match, true))}
    end)
  end

  defp limit_to_context_window(data, nil), do: data

  defp limit_to_context_window(data, budget) when is_integer(budget) and budget >= 0 do
    {answer, _} =
      Enum.reduce_while(data, {[], 0}, fn chunk, {acc, acc_tokens} ->
        output_tokens = chunk |> Jason.encode!() |> TokenEstimator.estimate()

        if acc_tokens + output_tokens < budget do
          {:cont, {[chunk | acc], acc_tokens + output_tokens}}
        else
          {:halt, {acc, acc_tokens}}
        end
      end)

    Enum.reverse(answer)
  end

  @doc "Applies the caller's result-count ceiling and optional token budget after ranking."
  def limit_chunks(chunks, max_total_results \\ 100, token_budget \\ nil)

  def limit_chunks(chunks, maximum, token_budget)
      when is_list(chunks) and is_integer(maximum) and maximum > 0 and
             (is_nil(token_budget) or (is_integer(token_budget) and token_budget >= 0)),
      do: chunks |> Enum.take(maximum) |> limit_to_context_window(token_budget)

  def limit_chunks(_chunks, maximum, _token_budget)
      when not is_integer(maximum) or maximum <= 0,
      do: {:error, :invalid_max_total_results}

  def limit_chunks(_chunks, _maximum, _token_budget), do: {:error, :invalid_token_budget}

  defp similarity_search_group_by(query_text, source_filter, language) do
    with {:ok, embedding} <- EmbeddingClient.embed(query_text),
         :ok <- validate_nonzero_embedding(embedding) do
      embedding_vector = Pgvector.HalfVector.new(embedding)
      threshold = max_cosine_distance()

      base =
        Chunk
        |> join(:inner, [c], d in Document, on: c.document_id == d.id, as: :doc)
        |> where([c, _d], fragment("? <=> ? <= ?", c.embedding, ^embedding_vector, ^threshold))
        |> order_by([c, _d],
          asc: fragment("? <=> ?", c.embedding, ^embedding_vector),
          asc: c.document_id,
          asc: c.chunk_index
        )
        |> select([c, _d], %{
          chunk_id: c.id,
          document_id: c.document_id,
          section_path: c.section_path,
          chunk_index: c.chunk_index,
          vector_distance: fragment("? <=> ?", c.embedding, ^embedding_vector)
        })

      base = FTSBackend.maybe_filter_language(base, language)

      query =
        if source_filter == [] do
          base
        else
          where(base, ^DocumentAccess.build_source_filter_condition(source_filter))
        end

      results = Repo.all(query)

      grouped =
        results
        |> Enum.group_by(& &1.document_id)
        |> Map.new(fn {doc_id, items} ->
          {doc_id, Enum.group_by(items, & &1.section_path)}
        end)

      {:ok, grouped}
    end
  end

  @doc """
  BM25 full-text search grouped by document and section path.

  Returns `{:ok, %{doc_id => %{section_path => [%{document_id, section_path, bm25_score}]}}}`.
  Mirrors the output shape of `similarity_search_group_by/1` so both legs can
  be fed into `rrf_merge/2` without transformation.

  When `source_filter` is non-empty, adds an INNER JOIN on `documents` and filters
  results to chunks whose document source matches one of the given prefixes.
  Files (paths containing a `.` in the last segment) are matched exactly;
  folders and connectors are matched via prefix (`LIKE "prefix/%"`).
  """
  def bm25_search_group_by(query_text, limit, source_filter \\ [], language \\ nil) do
    if is_nil(language) do
      FTSBackend.impl().bm25_search_group_by(query_text, limit, source_filter)
    else
      FTSBackend.impl().bm25_search_group_by(query_text, limit, source_filter, language)
    end
  end

  # ---------------------------------------------------------------------------
  # RRF merge (Elixir-side fusion of BM25 and vector legs)
  # ---------------------------------------------------------------------------

  @doc """
  Fuses BM25 and vector candidates by document and chunk index using weighted
  Reciprocal Rank Fusion. Section paths are retained for later context hydration,
  but different chunks in a section cannot boost one another.

  Each leg is ranked independently (rank 1..N by score). Chunks missing from
  a leg contribute 0 from that leg.

  Score: `bm25_w * 1/(k + bm25_rank) + vector_w * 1/(k + vector_rank)`

  Returns `{:ok, %{doc_id => %{section_path => [chunk match maps]}}}`.
  Every candidate must carry its persisted `chunk_index`.
  """
  def rrf_merge(bm25_grouped, vector_grouped) do
    {bm25_w, vector_w} = fusion_weights()
    k = @rrf_k

    bm25_ranked = rank_chunks(bm25_grouped, :bm25_score, :desc)
    vector_ranked = rank_chunks(vector_grouped, :vector_distance, :asc)

    all_keys =
      (Map.keys(bm25_ranked) ++ Map.keys(vector_ranked))
      |> Enum.uniq()

    merged =
      Enum.map(all_keys, fn {doc_id, chunk_index} = key ->
        {bm25_rank, bm25_match} = Map.get(bm25_ranked, key, {nil, nil})
        {vector_rank, vector_match} = Map.get(vector_ranked, key, {nil, nil})

        bm25_contrib = if bm25_rank, do: bm25_w * (1 / (k + bm25_rank)), else: 0.0
        vector_contrib = if vector_rank, do: vector_w * (1 / (k + vector_rank)), else: 0.0
        match = bm25_match || vector_match

        %{
          document_id: doc_id,
          chunk_id: Map.get(match, :chunk_id),
          section_path: match.section_path,
          chunk_index: chunk_index,
          rrf_score: bm25_contrib + vector_contrib,
          lexical_match: not is_nil(bm25_match),
          bm25_score: if(bm25_match, do: Map.get(bm25_match, :bm25_score, 0.0)),
          vector_distance: if(vector_match, do: vector_match.vector_distance)
        }
      end)

    grouped =
      merged
      |> Enum.group_by(& &1.document_id)
      |> Map.new(fn {doc_id, entries} ->
        by_path =
          entries
          |> Enum.group_by(& &1.section_path)
          |> Map.new(fn {path, matches} -> {path, Enum.sort_by(matches, & &1.chunk_index)} end)

        {doc_id, by_path}
      end)

    {:ok, grouped}
  end

  defp fusion_weights do
    cfg = Zaq.System.get_retrieval_config()
    {cfg.fusion_bm25_weight, cfg.fusion_vector_weight}
  end

  @doc """
  Fuses ordered, already hydrated retrieval legs without fetching content again.

  Uses ordinal ranks to retain the rank of redacted matches without disclosing
  their measured scores. Only the RRF score is taken from the existing merger;
  original measured scores and metadata are never replaced by ordinal surrogates.
  """
  def fuse_chunks(lexical, vector) do
    if valid_fusion_chunks?(lexical ++ vector) do
      lexical = Enum.uniq_by(lexical, &fusion_identity/1)
      vector = Enum.uniq_by(vector, &fusion_identity/1)

      originals =
        Enum.group_by(
          tag_leg(lexical, "lexical") ++ tag_leg(vector, "vector"),
          &fusion_identity/1
        )

      with {:ok, fused} <- rrf_merge(ranked_leg(lexical, :lexical), ranked_leg(vector, :vector)) do
        {:ok, %{chunks: fused_payload(fused, originals)}}
      end
    else
      {:error, :invalid_fusion_chunks}
    end
  end

  defp fused_payload(fused, originals) do
    fused
    |> ranked_matches(:hybrid)
    |> Enum.map(fn match ->
      originals[{match.document_id, match.chunk_index}]
      |> merge_fusion_evidence()
      |> Map.put("rrf_score", match.rrf_score)
    end)
  end

  defp valid_fusion_chunk?(%{
         "document_id" => doc_id,
         "chunk_index" => index,
         "section_path" => path
       }),
       do: is_integer(doc_id) and is_integer(index) and is_list(path)

  defp valid_fusion_chunk?(_chunk), do: false

  defp valid_fusion_chunks?(chunks) do
    Enum.all?(chunks, &valid_fusion_chunk?/1) and
      consistent_match_ids?(chunks) and consistent_chunk_locations?(chunks)
  end

  defp consistent_match_ids?(chunks) do
    chunks
    |> Enum.group_by(&fusion_identity/1)
    |> Enum.all?(fn {_identity, matches} ->
      paths = matches |> Enum.map(& &1["section_path"]) |> Enum.uniq()
      ids = matches |> Enum.map(& &1["chunk_id"]) |> Enum.reject(&is_nil/1) |> Enum.uniq()
      length(paths) == 1 and length(ids) <= 1
    end)
  end

  defp consistent_chunk_locations?(chunks) do
    chunks
    |> Enum.reject(&is_nil(&1["chunk_id"]))
    |> Enum.group_by(& &1["chunk_id"])
    |> Enum.all?(fn {_id, matches} ->
      matches |> Enum.map(&fusion_identity/1) |> Enum.uniq() |> length() == 1
    end)
  end

  defp fusion_identity(chunk), do: {chunk["document_id"], chunk["chunk_index"]}

  defp tag_leg(chunks, leg) do
    Enum.map(chunks, fn chunk ->
      if is_integer(chunk["chunk_id"]), do: Map.put(chunk, "retrieval_legs", [leg]), else: chunk
    end)
  end

  defp ranked_leg(chunks, leg) do
    chunks
    |> Enum.with_index(1)
    |> Enum.map(fn {chunk, rank} ->
      %{
        document_id: chunk["document_id"],
        section_path: chunk["section_path"],
        chunk_index: chunk["chunk_index"],
        chunk_id: chunk["chunk_id"],
        bm25_score: if(leg == :lexical, do: -rank),
        vector_distance: if(leg == :vector, do: rank)
      }
    end)
    |> Enum.group_by(& &1.document_id)
    |> Map.new(fn {doc_id, matches} -> {doc_id, Enum.group_by(matches, & &1.section_path)} end)
  end

  defp merge_fusion_evidence(chunks) do
    case Enum.find(chunks, &(not is_integer(&1["chunk_id"]))) do
      nil ->
        base = hd(chunks)

        legs =
          Enum.flat_map(chunks, &Map.get(&1, "retrieval_legs", [])) |> Enum.uniq() |> Enum.sort()

        measured = Enum.reduce(chunks, %{}, &merge_measured_scores/2)
        base |> Map.merge(measured) |> Map.put("retrieval_legs", legs)

      denied ->
        denied
    end
  end

  defp merge_measured_scores(chunk, scores) do
    Enum.reduce(["bm25_score", "vector_distance"], scores, fn key, acc ->
      if is_number(chunk[key]), do: Map.put(acc, key, chunk[key]), else: acc
    end)
  end

  defp rank_chunks(grouped, score_key, order) do
    grouped
    |> Enum.flat_map(fn {_doc_id, paths} ->
      Enum.flat_map(paths, fn {_path, matches} -> matches end)
    end)
    |> Enum.group_by(&{&1.document_id, &1.chunk_index})
    |> Enum.map(fn {key, matches} ->
      match =
        Enum.min_by(matches, fn item ->
          score = Map.get(item, score_key, 0.0)
          {if(order == :asc, do: score, else: -score), item.section_path}
        end)

      {key, match}
    end)
    |> Enum.sort_by(fn {{doc_id, chunk_index}, match} ->
      score = Map.get(match, score_key, 0.0)
      {if(order == :asc, do: score, else: -score), doc_id, chunk_index}
    end)
    |> Enum.with_index(1)
    |> Map.new(fn {{key, match}, rank} -> {key, {rank, match}} end)
  end

  # ---------------------------------------------------------------------------
  # Similarity search (vector only)
  # ---------------------------------------------------------------------------

  @doc """
  Performs vector similarity search.
  Returns chunks within `max_cosine_distance` ordered by cosine distance,
  with the document source included.
  """
  def similarity_search(query_text, limit \\ 5) do
    with {:ok, embedding} <- EmbeddingClient.embed(query_text),
         :ok <- validate_nonzero_embedding(embedding) do
      embedding_vector = Pgvector.HalfVector.new(embedding)
      threshold = max_cosine_distance()

      results =
        Chunk
        |> join(:inner, [c], d in Document, on: c.document_id == d.id)
        |> where(
          [c, _d],
          fragment("? <=> ? <= ?", c.embedding, ^embedding_vector, ^threshold)
        )
        |> order_by([c, _d], fragment("? <=> ?", c.embedding, ^embedding_vector))
        |> limit(^limit)
        |> select([c, d], %{
          chunk: c,
          source: d.source,
          vector_distance: fragment("? <=> ?", c.embedding, ^embedding_vector)
        })
        |> Repo.all()

      {:ok, results}
    end
  end

  # ---------------------------------------------------------------------------
  # Similarity search count (hybrid union count)
  # ---------------------------------------------------------------------------

  @doc """
  Returns the count of unique chunks matching via BM25+vector union search.
  """
  def similarity_search_count(query_text) do
    with {:ok, embedding} <- EmbeddingClient.embed(query_text),
         :ok <- validate_nonzero_embedding(embedding) do
      embedding_vector = Pgvector.HalfVector.new(embedding)
      limit = hybrid_search_limit()

      fts_ids = fts_count_query(query_text, limit)

      vector_ids =
        from(c in Chunk,
          order_by: fragment("? <=> ?", c.embedding, ^embedding_vector),
          select: %{id: c.id},
          limit: ^limit
        )

      combined =
        from(
          c in subquery(union_all(fts_ids, ^vector_ids)),
          select: count(c.id, :distinct)
        )

      {:ok, Repo.one(combined)}
    end
  end

  defp fts_count_query(query_text, limit) do
    FTSBackend.impl().fts_count_query(query_text, limit)
  end
end
