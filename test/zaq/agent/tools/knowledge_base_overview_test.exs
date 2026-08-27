defmodule Zaq.Agent.Tools.KnowledgeBaseOverviewTest do
  use Zaq.DataCase, async: true

  alias Zaq.Agent.Tools.KnowledgeBaseOverview
  alias Zaq.Ingestion.{Chunk, Document, DocumentAccess}

  # Routes directly to DocumentAccess without going through a real node boundary.
  defmodule PassthroughRouter do
    def call(:ingestion, DocumentAccess, :list_files_with_ingestion_status, [opts]) do
      DocumentAccess.list_files_with_ingestion_status(opts)
    end

    def call(_role, _mod, :broadcast_status, _args), do: :ok
  end

  setup do
    Chunk.create_table(1536)
    :ok
  end

  defp create_doc(source) do
    {:ok, doc} =
      Document.create(%{
        source: source,
        content: "content for #{source}",
        metadata: %{}
      })

    doc
  end

  defp create_ingested_doc(source) do
    doc = create_doc(source)
    {:ok, _} = Chunk.create(%{document_id: doc.id, content: "chunk", chunk_index: 0})

    doc
  end

  defp base_context do
    %{status_context: nil, node_router: PassthroughRouter, skip_permissions: true}
  end

  describe "run/2 — full path integration (skip_permissions: true)" do
    test "returns correct total and ingested_count for indexed documents" do
      _ingested = create_ingested_doc("full-path/ingested.md")
      _not_ingested = create_doc("full-path/raw.md")

      {:ok, result} = KnowledgeBaseOverview.run(%{}, base_context())

      assert result.total == 2
      assert result.ingested_count == 1
    end

    test "every document in results has a preview_url" do
      create_doc("preview/file.md")

      {:ok, result} = KnowledgeBaseOverview.run(%{}, base_context())

      assert Enum.all?(result.documents, fn doc ->
               is_binary(doc.preview_url) and String.starts_with?(doc.preview_url, "/bo/preview/")
             end)
    end

    test "ingested file has ingested: true and correct preview_url" do
      source = "tag/doc.md"
      create_ingested_doc(source)

      {:ok, result} = KnowledgeBaseOverview.run(%{}, base_context())

      entry = Enum.find(result.documents, fn d -> d.source == source end)
      assert entry != nil
      assert entry.ingested == true
      assert entry.preview_url == "/bo/preview/#{source}"
    end

    test "indexed file with no chunks has ingested: false and correct preview_url" do
      source = "tag/raw.md"
      create_doc(source)

      {:ok, result} = KnowledgeBaseOverview.run(%{}, base_context())

      entry = Enum.find(result.documents, fn d -> d.source == source end)
      assert entry != nil
      assert entry.ingested == false
      assert entry.preview_url == "/bo/preview/#{source}"
    end

    test "source_filter restricts documents to matching folder" do
      in_source = "filter-target/a.md"
      out_source = "filter-other/b.md"
      create_doc(in_source)
      create_doc(out_source)

      ctx = Map.put(base_context(), :source_filter, ["filter-target"])
      {:ok, result} = KnowledgeBaseOverview.run(%{}, ctx)

      sources = Enum.map(result.documents, & &1.source)
      assert in_source in sources
      refute out_source in sources
      assert result.total == length(result.documents)
    end

    test "standalone indexed .md appears even when same-name .pdf is indexed" do
      create_doc("markdown-companion-test/product.pdf")
      md_source = "markdown-companion-test/product.md"
      create_doc(md_source)

      {:ok, result} = KnowledgeBaseOverview.run(%{}, base_context())

      sources = Enum.map(result.documents, & &1.source)
      assert md_source in sources
    end

    test "returns error tuple when router returns error" do
      defmodule ErrorRouter do
        def call(:ingestion, DocumentAccess, :list_files_with_ingestion_status, [_opts]) do
          {:error, :simulated_failure}
        end

        def call(_role, _mod, :broadcast_status, _args), do: :ok
      end

      ctx = %{status_context: nil, node_router: ErrorRouter, skip_permissions: true}
      assert {:error, message} = KnowledgeBaseOverview.run(%{}, ctx)
      assert message =~ "Document count failed"
    end
  end
end
