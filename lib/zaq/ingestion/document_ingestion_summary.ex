defmodule Zaq.Ingestion.DocumentIngestionSummary do
  @moduledoc """
  Derives document-level ingestion progress from persisted child jobs and chunks.

  The job rows describe the current run; a completed job only counts as indexed
  when its corresponding chunk is actually present. The document metadata is a
  display snapshot, never the authoritative source of chunk status. Call `refresh/2`
  inside the parent-job lock so concurrent child completions cannot lose updates.
  """

  import Ecto.Query

  alias Zaq.Ingestion.{Chunk, Document, FTSBackend, IngestChunkJob, IngestJob, LanguageDetector}
  alias Zaq.Repo

  @max_errors 50

  @doc "Builds a versioned progress snapshot from one ingestion run."
  def build(jobs, chunks) when is_list(jobs) and is_list(chunks) do
    indexed_by_position = Map.new(chunks, &{&1.chunk_index, &1})

    indexed =
      jobs
      |> Enum.filter(
        &(&1.status == "completed" and Map.has_key?(indexed_by_position, &1.chunk_index))
      )
      |> Enum.map(&Map.fetch!(indexed_by_position, &1.chunk_index))

    detected_languages =
      jobs |> Enum.map(&detected_language/1) |> Enum.uniq() |> Enum.sort()

    indexed_languages =
      indexed |> Enum.map(&(&1.language || "simple")) |> Enum.uniq() |> Enum.sort()

    errors =
      jobs
      |> Enum.filter(&(&1.status == "failed_final"))
      |> Enum.sort_by(& &1.chunk_index)
      |> Enum.take(@max_errors)
      |> Enum.map(fn job ->
        %{
          "chunk_index" => job.chunk_index,
          "language" => detected_language(job),
          "stage" => "indexing",
          "code" => "chunk_failed",
          "message" => job.error || "Chunk indexing failed"
        }
      end)

    %{
      "version" => 1,
      "total_chunks_detected" => length(jobs),
      "total_chunks_indexed" => length(indexed),
      "total_chunks_simple_indexed" =>
        Enum.count(indexed, fn c ->
          get_in(c.metadata || %{}, ["search_configuration"]) == "simple" or
            c.language == "simple"
        end),
      "index_backend" => index_backend(),
      "detected_languages" => detected_languages,
      "indexed_languages" => indexed_languages,
      "errors" => errors,
      "total_errors" => Enum.count(jobs, &(&1.status == "failed_final"))
    }
  end

  @doc "Persists current-run progress while preserving unrelated document metadata."
  def refresh(job, opts \\ [])

  def refresh(%IngestJob{document_id: nil}, _opts), do: :ok

  def refresh(%IngestJob{} = job, opts) do
    document =
      Document |> where([d], d.id == ^job.document_id) |> lock("FOR UPDATE") |> Repo.one()

    if document do
      previous = Map.get(document.metadata || %{}, "ingestion", %{})

      if Keyword.get(opts, :new_run, false) or Map.get(previous, "job_id") in [nil, job.id] do
        jobs = Repo.all(from(c in IngestChunkJob, where: c.ingest_job_id == ^job.id))

        chunks =
          Repo.all(
            from(c in Chunk,
              where: c.document_id == ^document.id,
              select: %{chunk_index: c.chunk_index, language: c.language, metadata: c.metadata}
            )
          )

        summary =
          jobs
          |> build(chunks)
          |> Map.merge(%{
            "job_id" => job.id,
            "status" => job.status,
            "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
          })

        metadata = Map.put(document.metadata || %{}, "ingestion", summary)
        document |> Document.changeset(%{metadata: metadata}) |> Repo.update!()
      end
    end

    :ok
  end

  @doc "Updates progress for the direct, non-Oban ingestion path."
  def refresh_inline(document_id, detected_chunks, results, reset?) do
    Repo.transaction(fn ->
      document = Document |> where([d], d.id == ^document_id) |> lock("FOR UPDATE") |> Repo.one()

      if document, do: persist_inline(document, detected_chunks, results, reset?)
    end)
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp persist_inline(document, detected_chunks, results, reset?) do
    previous = if reset?, do: %{}, else: Map.get(document.metadata || %{}, "ingestion") || %{}
    persisted = Chunk.list_by_document(document.id)
    errors = inline_errors(previous, detected_chunks, results)

    summary = %{
      "version" => 1,
      "status" => if(errors == [], do: "completed", else: "completed_with_errors"),
      "total_chunks_detected" => length(detected_chunks),
      "total_chunks_indexed" => length(persisted),
      "total_chunks_simple_indexed" => Enum.count(persisted, &simple_indexed?/1),
      "index_backend" => index_backend(),
      "detected_languages" =>
        detected_chunks |> Enum.map(&chunk_language/1) |> Enum.uniq() |> Enum.sort(),
      "indexed_languages" =>
        persisted |> Enum.map(&(&1.language || "simple")) |> Enum.uniq() |> Enum.sort(),
      "errors" => Enum.take(errors, @max_errors),
      "total_errors" => length(errors),
      "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    metadata = Map.put(document.metadata || %{}, "ingestion", summary)
    document |> Document.changeset(%{metadata: metadata}) |> Repo.update!()
  end

  defp inline_errors(previous, detected_chunks, results) do
    successful_indices = for {index, {:ok, _}} <- results, is_integer(index), do: index

    new_errors =
      for {index, {:error, _}} <- results, is_integer(index) do
        %{
          "chunk_index" => index,
          "language" => detected_chunks |> Enum.at(index - 1) |> chunk_language(),
          "stage" => "indexing",
          "code" => "chunk_failed",
          "message" => "Chunk indexing failed"
        }
      end

    (Map.get(previous, "errors", []) ++ new_errors)
    |> Enum.reject(&(&1["chunk_index"] in successful_indices))
    |> Enum.uniq_by(& &1["chunk_index"])
    |> Enum.sort_by(& &1["chunk_index"])
  end

  defp simple_indexed?(chunk) do
    get_in(chunk.metadata || %{}, ["search_configuration"]) == "simple" or
      chunk.language == "simple"
  end

  defp index_backend do
    case FTSBackend.impl() do
      FTSBackend.ParadeDB -> "parade_db"
      FTSBackend.Native -> "native"
    end
  end

  defp detected_language(job) do
    payload = job.chunk_payload || %{}
    Map.get(payload, "language") || LanguageDetector.detect(Map.get(payload, "content", ""))
  end

  defp chunk_language(%{content: content}) when is_binary(content),
    do: LanguageDetector.detect(content)

  defp chunk_language(_), do: "simple"
end
