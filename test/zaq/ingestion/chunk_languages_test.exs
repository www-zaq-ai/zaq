defmodule Zaq.Ingestion.ChunkLanguagesTest do
  use Zaq.DataCase, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Zaq.Ingestion.{Chunk, ChunkLanguages, Document}
  alias Zaq.Repo

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

  test "serves cached languages until explicit invalidation" do
    Chunk.create_table(1536)

    pid = Process.whereis(ChunkLanguages) || start_supervised!(ChunkLanguages)
    Sandbox.allow(Repo, self(), pid)

    {:ok, document} =
      Document.create(%{source: "language-cache-hit-#{System.unique_integer([:positive])}"})

    assert {:ok, chunk} =
             Chunk.create(%{
               document_id: document.id,
               chunk_index: 1,
               content: "bonjour",
               language: "french"
             })

    ChunkLanguages.invalidate()
    _ = :sys.get_state(pid)
    assert "french" in ChunkLanguages.list()

    Repo.update_all(from(c in Chunk, where: c.id == ^chunk.id), set: [language: "german"])

    assert "french" in ChunkLanguages.list()
    refute "german" in ChunkLanguages.list()

    ChunkLanguages.invalidate()
    _ = :sys.get_state(pid)
    assert "german" in ChunkLanguages.list()
    refute "french" in ChunkLanguages.list()
  end
end
