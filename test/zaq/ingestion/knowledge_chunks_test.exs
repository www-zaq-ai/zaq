defmodule Zaq.Ingestion.KnowledgeChunksTest do
  use Zaq.DataCase, async: false
  use ExUnitProperties

  alias Zaq.Ingestion.{Api, Chunk, Document, KnowledgeChunks}
  alias Zaq.Repo

  setup do
    Chunk.create_table(1536)
    :ok
  end

  defp document do
    {:ok, doc} =
      Document.upsert(%{source: "navigation-#{System.unique_integer([:positive])}.md"})

    doc
  end

  defp chunk(doc, index, attrs \\ %{}) do
    %Chunk{}
    |> Chunk.changeset(
      Map.merge(
        %{document_id: doc.id, chunk_index: index, content: "chunk #{index}", section_path: []},
        attrs
      )
    )
    |> Repo.insert!()
  end

  defp match(chunk, score \\ 0.1) do
    %{
      document_id: chunk.document_id,
      chunk_index: chunk.chunk_index,
      section_path: chunk.section_path,
      rrf_score: score,
      lexical_match: false,
      vector_distance: 0.2
    }
  end

  test "navigation crosses sections and languages but never documents or just matching rows" do
    doc = document()
    other = document()
    first = chunk(doc, 1, %{section_path: ["first"], language: "english"})
    _other = chunk(other, 2)
    middle = chunk(doc, 4, %{section_path: ["middle"], language: "french"})
    last = chunk(doc, 9, %{section_path: ["last"], language: "english"})

    results = KnowledgeChunks.hydrate([match(last), match(first)], skip_permissions: true)
    by_id = Map.new(results, &{&1["chunk_id"], &1})

    assert map_size(by_id) == 2
    assert by_id[first.id]["previous_chunk_id"] == nil
    assert by_id[first.id]["next_chunk_id"] == middle.id
    assert by_id[last.id]["previous_chunk_id"] == middle.id
    assert by_id[last.id]["next_chunk_id"] == nil
    refute Map.has_key?(by_id, middle.id)
    assert Enum.all?(results, & &1["direct_match"])
  end

  test "inaccessible search matches reveal no chunk IDs, navigation or private metadata" do
    doc = document()
    first = chunk(doc, 1, %{metadata: %{secret: "private"}})
    _next = chunk(doc, 2)

    assert [denied] = KnowledgeChunks.hydrate([match(first)], [])
    assert denied["content"] == KnowledgeChunks.access_denied_message()

    for key <-
          ~w(chunk_id previous_chunk_id next_chunk_id metadata title language vector_distance direct_match) do
      refute Map.has_key?(denied, key)
    end
  end

  test "empty hydration performs no database reads" do
    assert {[], []} = Zaq.QueryRecorder.capture(fn -> KnowledgeChunks.hydrate([], []) end)
  end

  test "exact fetch returns unique requested chunks in request order without inference scores" do
    doc = document()
    first = chunk(doc, 1)
    middle = chunk(doc, 3)
    last = chunk(doc, 8)

    assert {:ok, %{chunks: [a, b], count: 2, unavailable_ids: []}} =
             KnowledgeChunks.fetch([last.id, first.id, last.id], skip_permissions: true)

    assert [a["chunk_id"], b["chunk_id"]] == [last.id, first.id]
    assert a["previous_chunk_id"] == middle.id
    assert b["next_chunk_id"] == middle.id
    refute Map.has_key?(a, "rrf_score")
    refute Map.has_key?(a, "direct_match")
  end

  test "missing, inaccessible and out-of-source IDs are unavailable without disclosing why" do
    public_doc = document()
    private_doc = document()
    {:ok, _} = Zaq.Permissions.grant_public(public_doc)
    public = chunk(public_doc, 1)
    private = chunk(private_doc, 1)
    missing_id = max(public.id, private.id) + 1

    assert {:ok, %{chunks: [found], unavailable_ids: unavailable}} =
             KnowledgeChunks.fetch([private.id, public.id, missing_id])

    assert found["chunk_id"] == public.id
    assert unavailable == [private.id, missing_id]

    assert {:ok, %{chunks: [], count: 0, unavailable_ids: [id]}} =
             KnowledgeChunks.fetch([public.id], source_filter: ["another-connector"])

    assert id == public.id
  end

  test "exact fetch rechecks permissions and handles deleted IDs" do
    doc = document()
    {:ok, grant} = Zaq.Permissions.grant_public(doc)
    first = chunk(doc, 1)
    assert {:ok, %{count: 1}} = KnowledgeChunks.fetch([first.id])
    :ok = Zaq.Permissions.revoke(doc, grant)
    assert {:ok, %{count: 0, unavailable_ids: [id]}} = KnowledgeChunks.fetch([first.id])
    assert id == first.id
    Repo.delete!(first)

    assert {:ok, %{count: 0, unavailable_ids: [^id]}} =
             KnowledgeChunks.fetch([first.id], skip_permissions: true)
  end

  test "invalid ID lists fail before a database read" do
    for invalid <- [[], [0], [-1], ["1"], [1.0], nil] do
      assert {{:error, :invalid_chunk_ids}, []} =
               Zaq.QueryRecorder.capture(fn -> KnowledgeChunks.fetch(invalid) end)
    end
  end

  test "the Ingestion event applies the same exact-fetch authorization" do
    doc = document()
    first = chunk(doc, 1)

    event =
      Zaq.Event.new(
        %{chunk_ids: [first.id], access_opts: []},
        :ingestion,
        opts: [action: :get_knowledge_base_chunks]
      )

    assert %{response: {:ok, %{chunks: [], count: 0, unavailable_ids: [id]}}} =
             Api.handle_event(event, :get_knowledge_base_chunks, %{})

    assert id == first.id
  end

  property "neighbors follow persisted ordinal order including gaps" do
    check all(
            indices <- uniq_list_of(integer(0..100), min_length: 1, max_length: 12),
            max_runs: 20
          ) do
      doc = document()
      ordered = indices |> Enum.sort() |> Enum.map(&chunk(doc, &1))
      results = KnowledgeChunks.hydrate(Enum.map(ordered, &match/1), skip_permissions: true)
      by_id = Map.new(results, &{&1["chunk_id"], &1})

      for {current, index} <- Enum.with_index(ordered) do
        previous = if index > 0, do: Enum.at(ordered, index - 1).id
        next = Enum.at(ordered, index + 1)
        assert by_id[current.id]["previous_chunk_id"] == previous
        assert by_id[current.id]["next_chunk_id"] == if(next, do: next.id)
      end
    end
  end
end
