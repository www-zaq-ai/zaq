defmodule Zaq.Ingestion.DocumentAccessSkipPermissionsTest do
  use Zaq.DataCase, async: true

  alias Zaq.Ingestion.{Chunk, Document, DocumentAccess}

  import Zaq.SystemConfigFixtures

  setup do
    seed_embedding_config(%{model: "test-model", dimension: "1536"})
    :ok
  end

  defp create_doc(source, attrs \\ %{}) do
    {:ok, doc} =
      %{source: source, content: "content for #{source}", metadata: %{}}
      |> Map.merge(attrs)
      |> Document.create()

    doc
  end

  defp insert_chunk_for(doc) do
    {:ok, _chunk} = Chunk.create(%{document_id: doc.id, content: "chunk", chunk_index: 0})
  end

  describe "list_files_with_ingestion_status/1 — skip_permissions: true" do
    test "bypasses permissions but does not invent filesystem entries" do
      private_doc = create_doc("private/indexed.md")
      insert_chunk_for(private_doc)

      result = DocumentAccess.list_files_with_ingestion_status(skip_permissions: true)

      assert Enum.any?(result, &(&1.source == private_doc.source and &1.ingested == true))
    end

    test "source_filter with exact file path matches only that indexed file" do
      target = create_doc("exact-filter/target.md")
      sibling = create_doc("exact-filter/sibling.md")
      insert_chunk_for(target)
      insert_chunk_for(sibling)

      result =
        DocumentAccess.list_files_with_ingestion_status(
          skip_permissions: true,
          source_filter: [target.source]
        )

      sources = Enum.map(result, & &1.source)
      assert sources == [target.source]
    end

    test "uploaded DB record with no chunks is tagged ingested: false" do
      doc = create_doc("bug/uploaded_not_ingested.md")

      result = DocumentAccess.list_files_with_ingestion_status(skip_permissions: true)
      entry = Enum.find(result, &(&1.source == doc.source))

      assert entry != nil
      assert entry.ingested == false
    end
  end
end
