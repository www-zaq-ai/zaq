defmodule Zaq.Ingestion.DocumentAccessFilesystemTest do
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

  describe "list_files_with_ingestion_status/1" do
    test "skip_permissions: true returns indexed documents only" do
      doc = create_doc("indexed.md")
      insert_chunk_for(doc)

      result = DocumentAccess.list_files_with_ingestion_status(skip_permissions: true)

      assert Enum.map(result, & &1.source) == ["indexed.md"]
      assert hd(result).ingested == true
    end

    test "document with no chunks is returned as not ingested" do
      doc = create_doc("uploaded-not-ingested.md")

      result = DocumentAccess.list_files_with_ingestion_status(skip_permissions: true)
      entry = Enum.find(result, &(&1.source == doc.source))

      assert entry != nil
      assert entry.ingested == false
    end

    test "source_filter restricts indexed documents" do
      in_doc = create_doc("subdir/in.md")
      out_doc = create_doc("outside.md")
      insert_chunk_for(in_doc)
      insert_chunk_for(out_doc)

      result =
        DocumentAccess.list_files_with_ingestion_status(
          skip_permissions: true,
          source_filter: ["subdir"]
        )

      assert Enum.map(result, & &1.source) == ["subdir/in.md"]
    end

    test "ingested doc carries its title field" do
      doc = create_doc("titled.md", %{title: "My Title"})
      insert_chunk_for(doc)

      result = DocumentAccess.list_files_with_ingestion_status(skip_permissions: true)
      entry = Enum.find(result, &(&1.source == doc.source))

      assert entry.ingested == true
      assert entry.title == "My Title"
    end
  end
end
