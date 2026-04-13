defmodule Zaq.Ingestion.Actions.AddToRag do
  @moduledoc """
  Finalises the RAG ingestion step and emits telemetry.

  Currently a thin pass-through that validates chunk counts and records telemetry.
  Exists as a named step so that future work — external vector DB sync, post-ingest
  webhooks, reranking triggers — has a clear place to land without touching the
  embedding or chunking actions.
  """

  use Jido.Action,
    name: "add_to_rag",
    description: "Finalises RAG ingestion: validates counts and emits telemetry.",
    schema: [
      document_id: [
        type: :any,
        required: true,
        doc: "Integer ID of the document"
      ],
      results: [
        type: :any,
        required: true,
        doc: "Per-chunk results list from EmbedChunks"
      ],
      ingested_count: [
        type: :integer,
        required: true,
        doc: "Number of chunks successfully embedded and stored"
      ],
      failed_count: [
        type: :integer,
        required: true,
        doc: "Number of chunks that failed embedding or storage"
      ]
    ]

  alias Zaq.Engine.Telemetry

  require Logger

  @impl true
  def run(
        %{
          document_id: document_id,
          ingested_count: ingested_count,
          failed_count: failed_count
        },
        _context
      ) do
    Logger.info(
      "[AddToRag] document #{document_id}: #{ingested_count} chunks in RAG, #{failed_count} failed"
    )

    Telemetry.record("ingestion.chunks.created", ingested_count, %{})

    {:ok, %{ingested_count: ingested_count, failed_count: failed_count}}
  end
end
