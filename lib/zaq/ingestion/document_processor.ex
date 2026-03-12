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
  alias Zaq.Ingestion.{Chunk, Document, DocumentChunker, FileExplorer}
  alias Zaq.Repo

  require Logger

  @rrf_k 60

  # ---------------------------------------------------------------------------
  # Config helpers
  # ---------------------------------------------------------------------------

  defp max_context_window do
    Application.get_env(:zaq, Zaq.Ingestion, [])
    |> Keyword.get(:max_context_window, 5_000)
  end

  defp distance_threshold do
    Application.get_env(:zaq, Zaq.Ingestion, [])
    |> Keyword.get(:distance_threshold, 0.75)
  end

  defp hybrid_search_limit do
    Application.get_env(:zaq, Zaq.Ingestion, [])
    |> Keyword.get(:hybrid_search_limit, 20)
  end

  defp chunk_title_module do
    Application.get_env(:zaq, :chunk_title_module, Zaq.Agent.ChunkTitle)
  end

  # ---------------------------------------------------------------------------
  # Ingestion - folder / single file
  # ---------------------------------------------------------------------------

  @doc """
  Processes all markdown files in the given folder path.

  ## Examples

      iex> Zaq.Ingestion.DocumentProcessor.process_folder("docs/")
      {:ok, %{processed: 5, failed: 0}}
  """
  def process_folder(folder_path) do
    files = Path.wildcard(Path.join(folder_path, "*.md"))
    Logger.info("Found #{length(files)} markdown files to process")

    results =
      files
      |> Enum.map(&process_single_file/1)
      |> Enum.reduce(%{processed: 0, failed: 0}, fn
        {:ok, _}, acc -> %{acc | processed: acc.processed + 1}
        {:error, _}, acc -> %{acc | failed: acc.failed + 1}
      end)

    {:ok, results}
  end

  @doc """
  Processes a single markdown file: read -> upsert document -> chunk -> embed -> store.
  """
  def process_single_file(file_path) do
    Logger.info("Processing file: #{file_path}")

    with {:ok, content} <- File.read(file_path),
         {:ok, source} <- extract_source(content, file_path),
         {:ok, document} <- store_document(content, source),
         {:ok, _chunks} <- process_and_store_chunks(content, document.id) do
      Logger.info("Successfully processed: #{source}")
      {:ok, document}
    else
      {:error, reason} = error ->
        Logger.error("Failed to process #{file_path}: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Extracts the source as a relative path from the ingestion base_path.
  Falls back to basename if the path is not under base_path.

  Example: "/app/priv/documents/docs/guide.md" => "docs/guide.md"
  """
  def extract_source(_content, file_path) do
    base = FileExplorer.base_path() |> Path.expand()
    expanded = Path.expand(file_path)

    relative =
      case String.split(expanded, base <> "/", parts: 2) do
        [_, rel] when rel != "" -> rel
        _ -> Path.basename(file_path)
      end

    {:ok, relative}
  end

  @doc """
  Upserts a `Zaq.Ingestion.Document` record.
  """
  def store_document(content, source) do
    case Document.upsert(%{content: content, source: source}) do
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
    Chunk.delete_by_document(document_id)
    sections = DocumentChunker.parse_layout(content, format: :markdown)
    chunks = DocumentChunker.chunk_sections(sections)

    Logger.info("Created #{length(chunks)} layout-aware chunks for document_id: #{document_id}")

    results =
      chunks
      |> Enum.with_index(1)
      |> Enum.map(fn {chunk, index} ->
        store_chunk_with_metadata(chunk, document_id, index)
      end)

    failed = Enum.count(results, &match?({:error, _}, &1))

    if failed == 0 do
      {:ok, results}
    else
      Logger.error("Failed to store #{failed} out of #{length(chunks)} chunks")
      first_error = Enum.find(results, &match?({:error, _}, &1))
      Logger.error("First error example: #{inspect(first_error)}")
      {:error, "#{failed} chunks failed to store"}
    end
  end

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
    base = %{
      document_id: document_id,
      chunk_index: index,
      section_id: chunk.section_id,
      section_path: chunk.section_path,
      section_type: chunk.metadata.section_type,
      section_level: chunk.metadata.section_level,
      position: chunk.metadata.position,
      tokens: chunk.tokens
    }

    case chunk.metadata.section_type do
      :figure ->
        figure_title = List.last(chunk.section_path) || ""
        Map.put(base, :figure_title, figure_title)

      _ ->
        base
    end
  end

  # ---------------------------------------------------------------------------
  # Query extraction (token-limited context for answering agent)
  # ---------------------------------------------------------------------------

  @doc """
  Extracts token-limited chunks for a given query using hybrid search.
  Returns a list of maps with `"content"`, `"source"`, and `"rrf_score"`.
  """
  def query_extraction(query) do
    with {:ok, results} <- hybrid_search(query) do
      answer = build_answer_from_results(results)
      {:ok, answer}
    end
  end

  defp build_answer_from_results(results) do
    {answer, _token_count} =
      Enum.reduce_while(results, {[], 0}, &accumulate_chunk/2)

    answer
  end

  defp accumulate_chunk(%{chunk: chunk, source: source, rrf_score: rrf_score}, {acc, acc_tokens}) do
    chunk_map = %{
      "content" => chunk.content,
      "source" => source,
      "rrf_score" => rrf_score
    }

    output_tokens =
      chunk_map
      |> Jason.encode!()
      |> TokenEstimator.estimate()

    if acc_tokens + output_tokens < max_context_window() do
      {:cont, {acc ++ [chunk_map], acc_tokens + output_tokens}}
    else
      {:halt, {acc, acc_tokens}}
    end
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
                LIMIT 20
              ) ts
              UNION
              SELECT id FROM (
                SELECT id,
                       ROW_NUMBER() OVER (ORDER BY embedding <-> ?) AS rn
                FROM chunks
                LIMIT 20
              ) vs
            )
            """,
            ^query_text,
            ^query_text,
            ^embedding_vector
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
                  LIMIT 20
                ) ts WHERE ts.id = c0.id
              )), 0)
              +
              COALESCE(1.0 / (? + (
                SELECT rn FROM (
                  SELECT id,
                         ROW_NUMBER() OVER (ORDER BY embedding <-> ?) AS rn
                  FROM chunks
                  LIMIT 20
                ) vs WHERE vs.id = c0.id
              )), 0)
              """,
              ^k,
              ^query_text,
              ^query_text,
              ^k,
              ^embedding_vector
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
                  LIMIT 20
                ) ts WHERE ts.id = c0.id
              )), 0)
              +
              COALESCE(1.0 / (? + (
                SELECT rn FROM (
                  SELECT id,
                         ROW_NUMBER() OVER (ORDER BY embedding <-> ?) AS rn
                  FROM chunks
                  LIMIT 20
                ) vs WHERE vs.id = c0.id
              )), 0)
              """,
              ^k,
              ^query_text,
              ^query_text,
              ^k,
              ^embedding_vector
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
