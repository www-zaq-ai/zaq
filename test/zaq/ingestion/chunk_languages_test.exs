defmodule Zaq.Ingestion.ChunkLanguagesTest do
  use Zaq.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Zaq.Ingestion.{Chunk, ChunkLanguages, Document}

  test "globally discovers persisted languages and invalidates after writes and deletion" do
    Chunk.create_table(1536)

    if is_nil(Process.whereis(ChunkLanguages)) do
      pid = start_supervised!(ChunkLanguages)
      Sandbox.allow(Zaq.Repo, self(), pid)
    end

    ChunkLanguages.invalidate()
    assert ChunkLanguages.list() == []

    {:ok, document} =
      Document.create(%{source: "language-cache-#{System.unique_integer([:positive])}"})

    assert {:ok, _} =
             Chunk.create(%{
               document_id: document.id,
               chunk_index: 1,
               content: "bonjour",
               language: "french"
             })

    assert "french" in ChunkLanguages.list()

    Chunk.delete_by_document(document.id)
    refute "french" in ChunkLanguages.list()
  end
end
