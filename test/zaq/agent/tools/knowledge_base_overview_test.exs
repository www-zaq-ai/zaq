defmodule Zaq.Agent.Tools.KnowledgeBaseOverviewTest do
  # async: false — modifies application env and writes to the filesystem
  use Zaq.DataCase, async: false

  alias Zaq.Agent.Tools.KnowledgeBaseOverview
  alias Zaq.Ingestion.{Chunk, Document, DocumentAccess, Sidecar}

  @test_base "test/tmp/knowledge_base_overview"

  # Routes directly to DocumentAccess without going through a real node boundary.
  defmodule PassthroughRouter do
    def dispatch(%Zaq.Event{request: %{module: mod, function: fun, args: args}} = event)
        when is_atom(mod) and is_atom(fun) and is_list(args) do
      %{event | response: apply(mod, fun, args)}
    end

    def dispatch(%Zaq.Event{} = event), do: %{event | response: :ok}
  end

  setup do
    Chunk.create_table(1536)
    File.rm_rf!(@test_base)
    File.mkdir_p!(@test_base)

    original = Application.get_env(:zaq, Zaq.Ingestion)
    Application.put_env(:zaq, Zaq.Ingestion, base_path: @test_base)

    on_exit(fn ->
      Application.put_env(:zaq, Zaq.Ingestion, original || [])
      File.rm_rf!(@test_base)
    end)

    :ok
  end

  defp write_file(rel_path) do
    abs = Path.join(@test_base, rel_path)
    abs |> Path.dirname() |> File.mkdir_p!()
    File.write!(abs, "content")
    rel_path
  end

  defp create_doc(source) do
    {:ok, doc} =
      Document.create(%{
        source: source,
        content: "content for #{source}",
        metadata: %{}
      })

    {:ok, _} = Chunk.create(%{document_id: doc.id, content: "chunk", chunk_index: 0})

    doc
  end

  defp base_context do
    %{status_context: nil, node_router: PassthroughRouter, skip_permissions: true}
  end

  describe "run/2 — full path integration (skip_permissions: true)" do
    test "returns correct total and ingested_count for mixed files" do
      ingested = write_file("full-path/ingested.md")
      _not_ingested = write_file("full-path/raw.md")
      create_doc(ingested)

      {:ok, result} = KnowledgeBaseOverview.run(%{}, base_context())

      assert result.total >= 2
      assert result.ingested_count >= 1
      assert result.ingested_count < result.total
    end

    test "every document in results has a preview_url" do
      write_file("preview/file.md")

      {:ok, result} = KnowledgeBaseOverview.run(%{}, base_context())

      assert Enum.all?(result.documents, fn doc ->
               is_binary(doc.preview_url) and String.starts_with?(doc.preview_url, "/bo/preview/")
             end)
    end

    test "ingested file has ingested: true and correct preview_url" do
      source = write_file("tag/doc.md")
      create_doc(source)

      {:ok, result} = KnowledgeBaseOverview.run(%{}, base_context())

      entry = Enum.find(result.documents, fn d -> d.source == source end)
      assert entry != nil
      assert entry.ingested == true
      assert entry.preview_url == "/bo/preview/#{source}"
    end

    test "non-ingested file has ingested: false and correct preview_url" do
      source = write_file("tag/raw.md")

      {:ok, result} = KnowledgeBaseOverview.run(%{}, base_context())

      entry = Enum.find(result.documents, fn d -> d.source == source end)
      assert entry != nil
      assert entry.ingested == false
      assert entry.preview_url == "/bo/preview/#{source}"
    end

    test "source_filter restricts documents to matching folder" do
      in_source = write_file("filter-target/a.md")
      out_source = write_file("filter-other/b.md")

      ctx = Map.put(base_context(), :source_filter, ["filter-target"])
      {:ok, result} = KnowledgeBaseOverview.run(%{}, ctx)

      sources = Enum.map(result.documents, & &1.source)
      assert in_source in sources
      refute out_source in sources
      assert result.total == length(result.documents)
    end

    test "standalone .md appears even when same-name .pdf exists" do
      write_file("sidecar-test/product.pdf")
      md_source = write_file("sidecar-test/product.md")

      {:ok, result} = KnowledgeBaseOverview.run(%{}, base_context())

      sources = Enum.map(result.documents, & &1.source)
      assert md_source in sources
    end

    test "confirmed sidecar .md is hidden when companion .pdf exists" do
      write_file("sidecar-confirmed/report.pdf")
      sidecar_source = write_file("sidecar-confirmed/report.md")

      Document.create(%{
        source: sidecar_source,
        content: "sidecar content",
        metadata: Sidecar.sidecar_metadata("sidecar-confirmed/report.pdf")
      })

      {:ok, result} = KnowledgeBaseOverview.run(%{}, base_context())

      sources = Enum.map(result.documents, & &1.source)
      refute sidecar_source in sources
    end

    test "returns error tuple when router returns error" do
      defmodule ErrorRouter do
        def dispatch(%Zaq.Event{} = event), do: %{event | response: {:error, :simulated_failure}}
      end

      ctx = %{status_context: nil, node_router: ErrorRouter, skip_permissions: true}
      assert {:error, message} = KnowledgeBaseOverview.run(%{}, ctx)
      assert message =~ "Document count failed"
    end
  end
end
