defmodule Zaq.Agent.Tools.ListKnowledgeBaseFilesTest do
  use Zaq.DataCase, async: true

  alias Zaq.Agent.Tools.ListKnowledgeBaseFiles
  alias Zaq.Ingestion.DocumentAccess

  # ---------------------------------------------------------------------------
  # Stub routers
  # ---------------------------------------------------------------------------

  defmodule StubRouter do
    def call(:ingestion, DocumentAccess, :list_files_with_ingestion_status, [_opts]) do
      {:ok,
       [
         %{source: "folder/doc.md", ingested: true, title: "A Document"},
         %{source: "folder/raw.txt", ingested: false}
       ]}
    end
  end

  defmodule EmptyRouter do
    def call(:ingestion, DocumentAccess, :list_files_with_ingestion_status, [_opts]) do
      {:ok, []}
    end
  end

  # Returns a plain list (no {:ok, _} wrapper) to exercise the passthrough clause
  # of unwrap_router_result/1.
  defmodule PlainListRouter do
    def call(:ingestion, DocumentAccess, :list_files_with_ingestion_status, [_opts]) do
      [%{source: "plain.md", ingested: true, title: "Plain"}]
    end
  end

  # Returns an error tuple — triggers the rescue path.
  defmodule ErrorRouter do
    def call(:ingestion, DocumentAccess, :list_files_with_ingestion_status, [_opts]) do
      {:error, :simulated_failure}
    end
  end

  # Asserts exact permission opts and returns an error for anything unexpected.
  defmodule PermissionRouter do
    def call(:ingestion, DocumentAccess, :list_files_with_ingestion_status, [
          [person_id: 42, team_ids: [1, 2], skip_permissions: false]
        ]) do
      {:ok, []}
    end

    def call(:ingestion, DocumentAccess, :list_files_with_ingestion_status, [opts]) do
      {:ok, [{:unexpected_opts, opts}]}
    end
  end

  # Captures the opts passed to the router for inspection.
  defmodule CaptureRouter do
    def call(:ingestion, DocumentAccess, :list_files_with_ingestion_status, [opts]) do
      send(self(), {:captured_opts, opts})
      {:ok, []}
    end
  end

  # ---------------------------------------------------------------------------
  # Basic behaviour
  # ---------------------------------------------------------------------------

  describe "run/2 — basic behaviour" do
    test "returns total, ingested_count, and documents on success" do
      context = %{person_id: 1, node_router: StubRouter}

      assert {:ok, result} = ListKnowledgeBaseFiles.run(%{}, context)
      assert result.total == 2
      assert result.ingested_count == 1
      assert length(result.documents) == 2
    end

    test "adds preview_url to each document" do
      context = %{person_id: 1, node_router: StubRouter}

      assert {:ok, result} = ListKnowledgeBaseFiles.run(%{}, context)
      sources = Enum.map(result.documents, & &1.source)
      assert "folder/doc.md" in sources

      doc = Enum.find(result.documents, fn d -> d.source == "folder/doc.md" end)
      assert doc.preview_url == "/bo/preview/folder/doc.md"
    end

    test "preview_url uses /bo/preview base path" do
      context = %{person_id: 1, node_router: StubRouter}

      assert {:ok, result} = ListKnowledgeBaseFiles.run(%{}, context)

      Enum.each(result.documents, fn doc ->
        assert String.starts_with?(doc.preview_url, "/bo/preview/")
      end)
    end

    test "returns zero totals when document list is empty" do
      context = %{node_router: EmptyRouter}

      assert {:ok, result} = ListKnowledgeBaseFiles.run(%{}, context)
      assert result.total == 0
      assert result.ingested_count == 0
      assert result.documents == []
    end

    test "ingested_count counts only ingested: true documents" do
      context = %{person_id: 1, node_router: StubRouter}

      assert {:ok, result} = ListKnowledgeBaseFiles.run(%{}, context)
      assert result.ingested_count == Enum.count(result.documents, & &1.ingested)
    end
  end

  # ---------------------------------------------------------------------------
  # unwrap_router_result
  # ---------------------------------------------------------------------------

  describe "run/2 — router result unwrapping" do
    test "unwraps {:ok, list} result from router" do
      context = %{node_router: StubRouter}

      assert {:ok, result} = ListKnowledgeBaseFiles.run(%{}, context)
      assert result.total == 2
    end

    test "passes through plain list result (no {:ok, _} wrapper)" do
      context = %{node_router: PlainListRouter}

      assert {:ok, result} = ListKnowledgeBaseFiles.run(%{}, context)
      assert result.total == 1
      assert hd(result.documents).source == "plain.md"
    end

    test "returns error tuple when router returns error and downstream raises" do
      context = %{node_router: ErrorRouter}

      assert {:error, message} = ListKnowledgeBaseFiles.run(%{}, context)
      assert String.contains?(message, "Document count failed:")
    end
  end

  # ---------------------------------------------------------------------------
  # Permission and context forwarding
  # ---------------------------------------------------------------------------

  describe "run/2 — permission enforcement" do
    test "forwards person_id and team_ids from context to router" do
      context = %{person_id: 42, team_ids: [1, 2], node_router: CaptureRouter}

      assert {:ok, _} = ListKnowledgeBaseFiles.run(%{}, context)

      assert_received {:captured_opts, opts}
      assert opts[:person_id] == 42
      assert opts[:team_ids] == [1, 2]
    end

    test "nil person_id is excluded from opts (nil is not an implicit permission grant)" do
      context = %{person_id: nil, node_router: CaptureRouter}

      assert {:ok, _} = ListKnowledgeBaseFiles.run(%{}, context)

      assert_received {:captured_opts, opts}
      refute Keyword.has_key?(opts, :person_id)
    end

    test "person_id absent from context is also excluded from opts" do
      context = %{node_router: CaptureRouter}

      assert {:ok, _} = ListKnowledgeBaseFiles.run(%{}, context)

      assert_received {:captured_opts, opts}
      refute Keyword.has_key?(opts, :person_id)
    end

    test "team_ids defaults to [] when absent from context" do
      context = %{person_id: 1, node_router: CaptureRouter}

      assert {:ok, _} = ListKnowledgeBaseFiles.run(%{}, context)

      assert_received {:captured_opts, opts}
      assert opts[:team_ids] == []
    end

    test "skip_permissions defaults to false" do
      context = %{person_id: 1, node_router: CaptureRouter}

      assert {:ok, _} = ListKnowledgeBaseFiles.run(%{}, context)

      assert_received {:captured_opts, opts}
      assert opts[:skip_permissions] == false
    end

    test "skip_permissions: true is forwarded from context" do
      context = %{skip_permissions: true, node_router: CaptureRouter}

      assert {:ok, _} = ListKnowledgeBaseFiles.run(%{}, context)

      assert_received {:captured_opts, opts}
      assert opts[:skip_permissions] == true
    end

    test "source_filter is forwarded when set" do
      context = %{source_filter: ["docs"], node_router: CaptureRouter}

      assert {:ok, _} = ListKnowledgeBaseFiles.run(%{}, context)

      assert_received {:captured_opts, opts}
      assert opts[:source_filter] == ["docs"]
    end

    test "nil source_filter is excluded from opts" do
      context = %{source_filter: nil, node_router: CaptureRouter}

      assert {:ok, _} = ListKnowledgeBaseFiles.run(%{}, context)

      assert_received {:captured_opts, opts}
      refute Keyword.has_key?(opts, :source_filter)
    end

    test "forwards exact person_id and team_ids to PermissionRouter without extra opts" do
      context = %{person_id: 42, team_ids: [1, 2], node_router: PermissionRouter}

      assert {:ok, result} = ListKnowledgeBaseFiles.run(%{}, context)
      assert result.documents == []
    end
  end

  # ---------------------------------------------------------------------------
  # Status broadcast with nil context does not crash
  # ---------------------------------------------------------------------------

  describe "run/2 — resilience" do
    test "runs without error when status_context is absent from context" do
      context = %{node_router: EmptyRouter}
      assert {:ok, _} = ListKnowledgeBaseFiles.run(%{}, context)
    end
  end

  # ---------------------------------------------------------------------------
  # Output format — LLM usability
  # ---------------------------------------------------------------------------

  describe "run/2 — output format" do
    test "tool result is JSON-encodable (LLM can receive it)" do
      context = %{person_id: 1, node_router: StubRouter}

      assert {:ok, result} = ListKnowledgeBaseFiles.run(%{}, context)
      assert {:ok, encoded} = Jason.encode(result)
      decoded = Jason.decode!(encoded)

      assert is_integer(decoded["total"])
      assert is_integer(decoded["ingested_count"])
      assert is_list(decoded["documents"])
    end

    test "each document in output has source, ingested, and preview_url keys" do
      context = %{person_id: 1, node_router: StubRouter}

      assert {:ok, result} = ListKnowledgeBaseFiles.run(%{}, context)

      Enum.each(result.documents, fn doc ->
        assert Map.has_key?(doc, :source)
        assert Map.has_key?(doc, :ingested)
        assert Map.has_key?(doc, :preview_url)
      end)
    end

    test "ingested_count matches number of ingested: true documents in JSON output" do
      context = %{person_id: 1, node_router: StubRouter}

      assert {:ok, result} = ListKnowledgeBaseFiles.run(%{}, context)
      assert {:ok, encoded} = Jason.encode(result)
      decoded = Jason.decode!(encoded)

      ingested_in_list = Enum.count(decoded["documents"], & &1["ingested"])
      assert decoded["ingested_count"] == ingested_in_list
    end
  end
end
