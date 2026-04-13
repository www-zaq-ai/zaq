defmodule Zaq.Ingestion.Actions.EmbedChunks do
  @moduledoc """
  Generates embeddings for each chunk and persists them to the vector store.

  Clears existing chunks for the document before inserting — matching the behaviour
  of the legacy `IngestWorker` — so re-ingesting a file produces a clean result.

  Each chunk is processed concurrently. Results include per-chunk outcome so that
  `AddToRag` can surface accurate ingested/failed counts.
  """

  use Jido.Action,
    name: "embed_chunks",
    description: "Embeds each chunk and inserts it into the pgvector store.",
    schema: [
      document_id: [
        type: :any,
        required: true,
        doc: "Integer ID of the parent document record"
      ],
      indexed_payloads: [
        type: :any,
        required: true,
        doc: "List of {payload_map, chunk_index} tuples from ChunkDocument"
      ]
    ]

  alias Zaq.Ingestion.{Chunk, DocumentChunker, JobLifecycle}

  require Logger

  @impl true
  def run(%{document_id: document_id, indexed_payloads: indexed_payloads}, context) do
    processor = Application.get_env(:zaq, :document_processor, Zaq.Ingestion.DocumentProcessor)
    job_id = Map.get(context, :job_id)
    total = length(indexed_payloads)

    if not is_nil(document_id), do: Chunk.delete_by_document(document_id)
    if not is_nil(job_id) and total > 0, do: JobLifecycle.set_total_chunks!(job_id, total)

    results =
      indexed_payloads
      |> Task.async_stream(
        fn {payload, index} ->
          chunk = payload_to_chunk(payload)
          result = processor.store_chunk_with_metadata(chunk, document_id, index)
          maybe_track_chunk_progress(job_id, result)
          {index, result}
        end,
        timeout: :infinity,
        max_concurrency: System.schedulers_online(),
        ordered: false
      )
      |> Enum.map(fn
        {:ok, result} -> result
        {:exit, reason} -> {nil, {:error, reason}}
      end)

    {ingested_count, failed_count} =
      Enum.reduce(results, {0, 0}, fn
        {_i, {:ok, _}}, {ok, err} -> {ok + 1, err}
        {_i, {:error, _}}, {ok, err} -> {ok, err + 1}
      end)

    Logger.info(
      "[EmbedChunks] document #{document_id}: #{ingested_count} embedded, #{failed_count} failed"
    )

    {:ok,
     %{
       document_id: document_id,
       results: results,
       ingested_count: ingested_count,
       failed_count: failed_count
     }}
  end

  defp maybe_track_chunk_progress(nil, _result), do: :ok

  defp maybe_track_chunk_progress(job_id, {:ok, _}),
    do: JobLifecycle.increment_chunk_progress!(job_id, :ingested)

  defp maybe_track_chunk_progress(job_id, _),
    do: JobLifecycle.increment_chunk_progress!(job_id, :failed)

  defp payload_to_chunk(payload) do
    struct(DocumentChunker.Chunk, %{
      id: Map.get(payload, "id"),
      section_id: Map.get(payload, "section_id"),
      content: Map.get(payload, "content", ""),
      section_path: Map.get(payload, "section_path", []),
      tokens: Map.get(payload, "tokens", 0),
      metadata: Map.get(payload, "metadata", %{})
    })
  end
end
