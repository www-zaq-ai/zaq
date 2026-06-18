defmodule Zaq.Ingestion.ParadeDBDottedLiteralTest do
  @moduledoc """
  Regression: dotted literals (IPv4, versions) must match through the ParadeDB
  BM25 backend.

  The BM25 index uses the default tokenizer, which splits on `.` at index time.
  `parse_with_field` re-tokenizes each query term with that same analyzer, so a
  query like `10.0.0.42` matches the indexed chunk regardless of whether the
  query sanitizer preserves the dots. This pins that behaviour so a future
  change to the sanitizer or the index tokenizer cannot silently break IP /
  version retrieval on ParadeDB (the Native counterpart lives in
  `bm25_fusion_validation_test.exs` §5).
  """
  use Zaq.DataCase, async: false

  alias Zaq.Ingestion.{Chunk, Document, FTSBackend}
  alias Zaq.Ingestion.FTSBackend.ParadeDB
  alias Zaq.Repo

  @embedding_dim 1536

  @content """
  ## Cluster Kubernetes

  IP du load balancer: `10.0.0.42`
  Version Traefik: 2.11.0
  """

  setup do
    FTSBackend.reset_cache()
    on_exit(fn -> FTSBackend.reset_cache() end)
    :ok
  end

  defp insert_chunk(content) do
    {:ok, doc} =
      %Document{}
      |> Document.changeset(%{
        source: "dotted_#{System.unique_integer([:positive])}.md",
        content: content
      })
      |> Repo.insert()

    %Chunk{}
    |> Chunk.changeset(%{
      document_id: doc.id,
      content: content,
      chunk_index: 1,
      section_path: ["Cluster Kubernetes"],
      language: "french",
      embedding: Pgvector.HalfVector.new(List.duplicate(0.1, @embedding_dim))
    })
    |> Repo.insert!()
  end

  @tag :paradedb
  test "ParadeDB backend is active and matches the IPv4 literal via parse_with_field" do
    Chunk.create_table(@embedding_dim)
    FTSBackend.reset_cache()
    assert FTSBackend.impl() == FTSBackend.ParadeDB, "expected ParadeDB to be the active backend"

    insert_chunk(@content)

    # Keyword leg
    assert {:ok, kw} = ParadeDB.bm25_search_group_by("load balancer", 20)
    assert map_size(kw) > 0, "ParadeDB must match the 'load balancer' keyword"

    # Dotted literal leg — the Bug 1 case
    assert {:ok, ip} = ParadeDB.bm25_search_group_by("10.0.0.42", 20)
    assert map_size(ip) > 0, "ParadeDB must match the IPv4 literal 10.0.0.42"

    # Version literal
    assert {:ok, ver} = ParadeDB.bm25_search_group_by("2.11.0", 20)
    assert map_size(ver) > 0, "ParadeDB must match the version literal 2.11.0"
  end
end
