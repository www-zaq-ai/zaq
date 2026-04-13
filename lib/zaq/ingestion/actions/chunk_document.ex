defmodule Zaq.Ingestion.Actions.ChunkDocument do
  @moduledoc """
  Reads the converted markdown, upserts the document record, and produces
  indexed chunk payloads ready for embedding.

  Delegates to `DocumentProcessor.prepare_file_chunks/1`. Because
  `ConvertToMarkdown` wrote the sidecar as a side effect, this call reads the
  already-existing sidecar instead of re-running conversion.
  """

  use Jido.Action,
    name: "chunk_document",
    description: "Stores the document record and splits content into indexed chunk payloads.",
    schema: [
      file_path: [
        type: :string,
        required: true,
        doc: "Absolute path to the source file"
      ]
    ]

  require Logger

  @impl true
  def run(%{file_path: file_path}, _context) do
    processor = Application.get_env(:zaq, :document_processor, Zaq.Ingestion.DocumentProcessor)

    case processor.prepare_file_chunks(file_path) do
      {:ok, document, indexed_payloads} ->
        Logger.info(
          "[ChunkDocument] #{length(indexed_payloads)} chunks prepared for document #{document.id}"
        )

        {:ok, %{document_id: document.id, indexed_payloads: indexed_payloads}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
