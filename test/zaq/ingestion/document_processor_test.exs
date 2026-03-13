defmodule Zaq.Ingestion.DocumentProcessorTest do
  use Zaq.DataCase, async: false

  import Mox

  alias Zaq.Agent.TokenEstimator
  alias Zaq.Ingestion.{Chunk, Document, DocumentChunker, DocumentProcessor}
  alias Zaq.Repo

  import Ecto.Query
  @moduletag capture_log: true

  setup :verify_on_exit!

  # ---------------------------------------------------------------------------
  # Test helpers
  # ---------------------------------------------------------------------------

  defp create_document(attrs \\ %{}) do
    default = %{
      source: "test-doc-#{System.unique_integer([:positive])}.md",
      content: "# Test\n\nSome content.",
      content_type: "markdown"
    }

    {:ok, doc} = Document.upsert(Map.merge(default, attrs))
    doc
  end

  defp stub_embedding_success(dimension \\ nil) do
    dim = dimension || embedding_dimension()

    Req.Test.stub(Zaq.Embedding.Client, fn conn ->
      body = Jason.encode!(%{"data" => [%{"embedding" => List.duplicate(0.1, dim)}]})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, body)
    end)
  end

  defp stub_embedding_wrong_dimension do
    Req.Test.stub(Zaq.Embedding.Client, fn conn ->
      body = Jason.encode!(%{"data" => [%{"embedding" => [0.1, 0.2]}]})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, body)
    end)
  end

  defp stub_embedding_failure do
    Req.Test.stub(Zaq.Embedding.Client, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(500, Jason.encode!(%{"error" => "Internal Server Error"}))
    end)
  end

  defp stub_embedding_fail_on_call(failing_call, dimension \\ nil) do
    dim = dimension || embedding_dimension()
    counter = start_supervised!({Agent, fn -> 0 end})

    Req.Test.stub(Zaq.Embedding.Client, fn conn ->
      call_number =
        Agent.get_and_update(counter, fn current ->
          next = current + 1
          {next, next}
        end)

      if call_number == failing_call do
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(500, Jason.encode!(%{"error" => "forced failure"}))
      else
        body = Jason.encode!(%{"data" => [%{"embedding" => List.duplicate(0.1, dim)}]})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, body)
      end
    end)
  end

  defp stub_chunk_title_success(title \\ "Generated Title") do
    Zaq.Agent.ChunkTitleMock
    |> stub(:ask, fn _content, _opts -> {:ok, title} end)
  end

  defp stub_chunk_title_failure do
    Zaq.Agent.ChunkTitleMock
    |> stub(:ask, fn _content, _opts -> {:error, "LLM unavailable"} end)
  end

  defp embedding_dimension do
    Application.get_env(:zaq, Zaq.Embedding.Client, [])
    |> Keyword.get(:dimension, 3584)
  end

  defp create_test_md_file(dir, filename, content) do
    path = Path.join(dir, filename)
    File.write!(path, content)
    path
  end

  # ---------------------------------------------------------------------------
  # extract_source/2
  # ---------------------------------------------------------------------------

  describe "extract_source/2" do
    setup do
      original = Application.get_env(:zaq, Zaq.Ingestion)

      on_exit(fn ->
        if is_nil(original) do
          Application.delete_env(:zaq, Zaq.Ingestion)
        else
          Application.put_env(:zaq, Zaq.Ingestion, original)
        end
      end)

      :ok
    end

    test "returns basename of file path" do
      assert {:ok, "report.md"} =
               DocumentProcessor.extract_source("ignored", "/some/path/report.md")
    end

    test "returns path relative to configured base_path" do
      base_dir = Path.join(System.tmp_dir!(), "zaq_base_#{System.unique_integer([:positive])}")
      Application.put_env(:zaq, Zaq.Ingestion, base_path: base_dir)

      file_path = Path.join([base_dir, "guides", "api", "reference.md"])

      assert {:ok, "guides/api/reference.md"} =
               DocumentProcessor.extract_source("ignored", file_path)
    end

    test "falls back to basename when path is outside configured base_path" do
      base_dir = Path.join(System.tmp_dir!(), "zaq_base_#{System.unique_integer([:positive])}")
      Application.put_env(:zaq, Zaq.Ingestion, base_path: base_dir)

      outside_path = Path.join(System.tmp_dir!(), "not-in-base.md")

      assert {:ok, "not-in-base.md"} =
               DocumentProcessor.extract_source("ignored", outside_path)
    end
  end

  # ---------------------------------------------------------------------------
  # store_document/2
  # ---------------------------------------------------------------------------

  describe "store_document/2" do
    test "inserts a new document" do
      {:ok, doc} = DocumentProcessor.store_document("# Hello", "new-file.md")
      assert doc.source == "new-file.md"
      assert doc.content == "# Hello"
    end

    test "upserts on conflict (same source)" do
      {:ok, _doc1} = DocumentProcessor.store_document("# V1", "same-source.md")
      {:ok, _doc2} = DocumentProcessor.store_document("# V2", "same-source.md")

      count =
        Repo.aggregate(
          from(d in Document, where: d.source == "same-source.md"),
          :count
        )

      assert count == 1
    end

    test "returns changeset error when required fields are invalid" do
      assert {:error, changeset} = DocumentProcessor.store_document(nil, nil)
      assert %{content: [_ | _], source: [_ | _]} = errors_on(changeset)
    end
  end

  # ---------------------------------------------------------------------------
  # build_metadata/3
  # ---------------------------------------------------------------------------

  describe "build_metadata/3" do
    test "builds base metadata for heading chunk" do
      chunk = %DocumentChunker.Chunk{
        id: "chunk_0_0",
        section_id: "sec1",
        content: "Some content",
        section_path: ["Chapter 1"],
        tokens: 10,
        metadata: %{
          section_type: :heading,
          section_level: 1,
          position: 0
        }
      }

      meta = DocumentProcessor.build_metadata(chunk, 42, 1)

      assert meta.document_id == 42
      assert meta.chunk_index == 1
      assert meta.section_id == "sec1"
      assert meta.section_type == :heading
      assert meta.section_level == 1
      assert meta.tokens == 10
      refute Map.has_key?(meta, :figure_title)
    end

    test "adds figure_title for figure chunks" do
      chunk = %DocumentChunker.Chunk{
        id: "chunk_1_0",
        section_id: "sec2",
        content: "Figure content",
        section_path: ["Chapter", "chart.png"],
        tokens: 5,
        metadata: %{
          section_type: :figure,
          section_level: nil,
          position: 3
        }
      }

      meta = DocumentProcessor.build_metadata(chunk, 42, 2)

      assert meta.figure_title == "chart.png"
      assert meta.section_type == :figure
    end

    test "uses empty figure_title when section_path is empty" do
      chunk = %DocumentChunker.Chunk{
        id: "chunk_2_0",
        section_id: "sec3",
        content: "Figure content",
        section_path: [],
        tokens: 3,
        metadata: %{section_type: :figure, section_level: nil, position: 1}
      }

      meta = DocumentProcessor.build_metadata(chunk, 99, 7)

      assert meta.figure_title == ""
    end
  end

  # ---------------------------------------------------------------------------
  # process_and_store_chunks/2
  # ---------------------------------------------------------------------------

  describe "process_and_store_chunks/2" do
    test "chunks content and inserts into database" do
      stub_embedding_success()
      stub_chunk_title_success()
      doc = create_document()

      content = """
      # Introduction

      This is the introduction paragraph with enough words to form a chunk.

      ## Details

      Here are some more details about the topic at hand.
      """

      {:ok, results} = DocumentProcessor.process_and_store_chunks(content, doc.id)
      assert is_list(results)
      assert results != []

      db_chunks = Repo.all(from(c in Chunk, where: c.document_id == ^doc.id))
      assert db_chunks != []
    end

    test "stores chunks even when title generation fails" do
      stub_embedding_success()
      stub_chunk_title_failure()
      doc = create_document()

      content = "# Heading\n\nSome content that will get the original title."

      {:ok, results} = DocumentProcessor.process_and_store_chunks(content, doc.id)
      assert results != []
    end

    test "returns error when embedding fails" do
      stub_embedding_failure()
      stub_chunk_title_success()
      doc = create_document()

      content = "# Heading\n\nSome content that will fail to embed."

      assert {:error, _} = DocumentProcessor.process_and_store_chunks(content, doc.id)
    end

    test "returns aggregated error when only some chunks fail to store" do
      stub_embedding_fail_on_call(2)
      stub_chunk_title_failure()
      doc = create_document()

      content = """
      # Chunk One

      First chunk content should insert successfully.

      # Chunk Two

      Second chunk content is expected to fail embedding.
      """

      assert {:error, "1 chunks failed to store"} =
               DocumentProcessor.process_and_store_chunks(content, doc.id)

      assert Repo.aggregate(from(c in Chunk, where: c.document_id == ^doc.id), :count) == 1
    end

    test "returns ok with empty results when chunker produces no chunks" do
      stub_embedding_success()
      stub_chunk_title_success()
      doc = create_document()

      assert {:ok, []} = DocumentProcessor.process_and_store_chunks("   \n\n", doc.id)
      assert Repo.aggregate(from(c in Chunk, where: c.document_id == ^doc.id), :count) == 0
    end
  end

  # ---------------------------------------------------------------------------
  # store_chunk_with_metadata/3
  # ---------------------------------------------------------------------------

  describe "store_chunk_with_metadata/3" do
    test "inserts chunk when embedding succeeds" do
      stub_embedding_success()
      stub_chunk_title_success()
      doc = create_document()

      chunk = %DocumentChunker.Chunk{
        id: "chunk_0_0",
        section_id: "sec1",
        content: "## Intro\n\nSome chunk content.",
        section_path: ["Intro"],
        tokens: 5,
        metadata: %{section_type: :heading, section_level: 2, position: 0}
      }

      assert {:ok, %Chunk{}} =
               DocumentProcessor.store_chunk_with_metadata(chunk, doc.id, 1)

      assert Repo.aggregate(
               from(c in Chunk, where: c.document_id == ^doc.id),
               :count
             ) == 1
    end

    test "chunk content includes generated title" do
      stub_embedding_success()
      stub_chunk_title_success("Custom LLM Title")
      doc = create_document()

      chunk = %DocumentChunker.Chunk{
        id: "chunk_0_0",
        section_id: "sec1",
        content: "## Old Heading\n\nSome chunk content.",
        section_path: ["Old Heading"],
        tokens: 5,
        metadata: %{section_type: :heading, section_level: 2, position: 0}
      }

      {:ok, record} = DocumentProcessor.store_chunk_with_metadata(chunk, doc.id, 1)
      assert String.contains?(record.content, "Custom LLM Title")
    end

    test "keeps original heading and section_path when generated title is empty" do
      stub_embedding_success()
      stub_chunk_title_success("")
      doc = create_document()

      chunk = %DocumentChunker.Chunk{
        id: "chunk_0_1",
        section_id: "sec1",
        content: "## Original Heading\n\nSome chunk content.",
        section_path: ["Original Heading"],
        tokens: 5,
        metadata: %{section_type: :heading, section_level: 2, position: 0}
      }

      {:ok, record} = DocumentProcessor.store_chunk_with_metadata(chunk, doc.id, 1)

      assert String.starts_with?(record.content, "## Original Heading")
      assert record.section_path == ["Original Heading"]
    end

    test "prepends generated heading when chunk has no heading" do
      stub_embedding_success()
      stub_chunk_title_success("Generated For Plain Chunk")
      doc = create_document()

      chunk = %DocumentChunker.Chunk{
        id: "chunk_0_2",
        section_id: "sec2",
        content: "Plain chunk content without heading.",
        section_path: ["Original Path"],
        tokens: 4,
        metadata: %{section_type: :paragraph, section_level: nil, position: 0}
      }

      {:ok, record} = DocumentProcessor.store_chunk_with_metadata(chunk, doc.id, 2)

      assert String.starts_with?(record.content, "## **Generated For Plain Chunk**\n\n")
      assert record.section_path == ["Generated For Plain Chunk"]
    end

    test "replaces markdown heading with generated emphasized heading" do
      stub_embedding_success()
      stub_chunk_title_success("Renamed Heading")
      doc = create_document()

      chunk = %DocumentChunker.Chunk{
        id: "chunk_replace_1",
        section_id: "sec-replace",
        content: "### **Legacy Heading**\n\nSome chunk content.",
        section_path: ["Legacy Heading"],
        tokens: 6,
        metadata: %{section_type: :heading, section_level: 3, position: 0}
      }

      {:ok, record} = DocumentProcessor.store_chunk_with_metadata(chunk, doc.id, 3)
      assert String.starts_with?(record.content, "## **Renamed Heading**\n\n")
    end

    test "replaces non-list section_path with generated single-entry path" do
      stub_embedding_success()
      stub_chunk_title_success("Path Normalized")
      doc = create_document()

      chunk = %DocumentChunker.Chunk{
        id: "chunk_0_3",
        section_id: "sec3",
        content: "Content without valid section_path list.",
        section_path: nil,
        tokens: 6,
        metadata: %{section_type: :paragraph, section_level: nil, position: 0}
      }

      {:ok, record} = DocumentProcessor.store_chunk_with_metadata(chunk, doc.id, 4)
      assert record.section_path == ["Path Normalized"]
    end

    test "returns error on dimension mismatch" do
      stub_embedding_wrong_dimension()
      stub_chunk_title_success()
      doc = create_document()

      chunk = %DocumentChunker.Chunk{
        id: "chunk_0_0",
        section_id: "sec1",
        content: "Content",
        section_path: [],
        tokens: 2,
        metadata: %{section_type: :paragraph, section_level: nil, position: 0}
      }

      assert {:error, :dimension_mismatch} =
               DocumentProcessor.store_chunk_with_metadata(chunk, doc.id, 1)
    end

    test "returns error when embedding call fails" do
      stub_embedding_failure()
      stub_chunk_title_success()
      doc = create_document()

      chunk = %DocumentChunker.Chunk{
        id: "chunk_0_0",
        section_id: "sec1",
        content: "Content",
        section_path: [],
        tokens: 2,
        metadata: %{section_type: :paragraph, section_level: nil, position: 0}
      }

      assert {:error, _} =
               DocumentProcessor.store_chunk_with_metadata(chunk, doc.id, 1)
    end

    test "returns changeset error when chunk insert fails foreign key" do
      stub_embedding_success()
      stub_chunk_title_success()

      chunk = %DocumentChunker.Chunk{
        id: "chunk_fk_0",
        section_id: "sec-fk",
        content: "Foreign key should fail for missing document.",
        section_path: ["Missing Doc"],
        tokens: 7,
        metadata: %{section_type: :heading, section_level: 2, position: 0}
      }

      assert {:error, changeset} =
               DocumentProcessor.store_chunk_with_metadata(chunk, -999_999, 1)

      assert %{document_id: [_ | _]} = errors_on(changeset)
    end
  end

  # ---------------------------------------------------------------------------
  # search paths error/default config branches
  # ---------------------------------------------------------------------------

  describe "search error/default config branches" do
    setup do
      original = Application.get_env(:zaq, Zaq.Ingestion)

      on_exit(fn ->
        if is_nil(original) do
          Application.delete_env(:zaq, Zaq.Ingestion)
        else
          Application.put_env(:zaq, Zaq.Ingestion, original)
        end
      end)

      :ok
    end

    test "hybrid_search/2 returns embedding errors" do
      stub_embedding_failure()
      assert {:error, _} = DocumentProcessor.hybrid_search("query")
    end

    test "similarity_search/2 returns embedding errors" do
      stub_embedding_failure()
      assert {:error, _} = DocumentProcessor.similarity_search("query")
    end

    test "similarity_search_count/1 returns embedding errors" do
      stub_embedding_failure()
      assert {:error, _} = DocumentProcessor.similarity_search_count("query")
    end

    test "hybrid_search/2 uses configured default limit when limit is nil" do
      stub_embedding_success()
      doc = create_document()

      dim = embedding_dimension()
      embedding = Pgvector.HalfVector.new(List.duplicate(0.1, dim))

      for i <- 1..3 do
        %Chunk{}
        |> Chunk.changeset(%{
          document_id: doc.id,
          content: "Configured limit chunk #{i} searchable text.",
          chunk_index: i,
          section_path: ["Limit"],
          metadata: %{section_type: :heading, section_level: 1, position: i},
          embedding: embedding
        })
        |> Repo.insert!()
      end

      Application.put_env(:zaq, Zaq.Ingestion, hybrid_search_limit: 1)

      assert {:ok, results} = DocumentProcessor.hybrid_search("searchable text")
      assert length(results) == 1
    end

    test "query_extraction/1 returns empty when max_context_window is too small" do
      stub_embedding_success()
      doc = create_document()

      dim = embedding_dimension()
      embedding = Pgvector.HalfVector.new(List.duplicate(0.1, dim))

      %Chunk{}
      |> Chunk.changeset(%{
        document_id: doc.id,
        content: "Token heavy chunk content for extraction.",
        chunk_index: 1,
        section_path: ["Tiny Window"],
        metadata: %{section_type: :heading, section_level: 1, position: 1},
        embedding: embedding
      })
      |> Repo.insert!()

      Application.put_env(:zaq, Zaq.Ingestion, max_context_window: 1)

      assert {:ok, []} = DocumentProcessor.query_extraction("token heavy")
    end
  end

  # ---------------------------------------------------------------------------
  # process_single_file/1
  # ---------------------------------------------------------------------------

  describe "process_single_file/1" do
    setup do
      stub_embedding_success()
      stub_chunk_title_success()

      tmp_dir =
        Path.join(System.tmp_dir!(), "zaq_test_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      {:ok, tmp_dir: tmp_dir}
    end

    test "processes a markdown file end-to-end", %{tmp_dir: tmp_dir} do
      content = "# Test Doc\n\nSome paragraph content here."
      path = create_test_md_file(tmp_dir, "test.md", content)

      assert {:ok, %Document{} = doc} = DocumentProcessor.process_single_file(path)
      assert doc.source == "test.md"

      chunks = Repo.all(from(c in Chunk, where: c.document_id == ^doc.id))
      assert chunks != []
    end

    test "returns error for missing file" do
      assert {:error, _} = DocumentProcessor.process_single_file("/nonexistent/file.md")
    end
  end

  # ---------------------------------------------------------------------------
  # process_folder/1
  # ---------------------------------------------------------------------------

  describe "process_folder/1" do
    setup do
      tmp_dir =
        Path.join(System.tmp_dir!(), "zaq_folder_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      {:ok, tmp_dir: tmp_dir}
    end

    test "processes all markdown files in folder", %{tmp_dir: tmp_dir} do
      stub_embedding_success()
      stub_chunk_title_success()
      create_test_md_file(tmp_dir, "a.md", "# Doc A\n\nContent A.")
      create_test_md_file(tmp_dir, "b.md", "# Doc B\n\nContent B.")
      create_test_md_file(tmp_dir, "readme.txt", "Not a markdown file.")

      assert {:ok, %{processed: 2, failed: 0}} =
               DocumentProcessor.process_folder(tmp_dir)
    end

    test "counts failures", %{tmp_dir: tmp_dir} do
      stub_embedding_failure()
      stub_chunk_title_success()
      create_test_md_file(tmp_dir, "fail.md", "# Will Fail\n\nContent.")

      assert {:ok, %{processed: 0, failed: 1}} =
               DocumentProcessor.process_folder(tmp_dir)
    end

    test "returns zero counts for empty folder", %{tmp_dir: tmp_dir} do
      assert {:ok, %{processed: 0, failed: 0}} =
               DocumentProcessor.process_folder(tmp_dir)
    end
  end

  # ---------------------------------------------------------------------------
  # query_extraction/1 (integration)
  # ---------------------------------------------------------------------------

  describe "query_extraction/1" do
    setup do
      original = Application.get_env(:zaq, Zaq.Ingestion)

      on_exit(fn ->
        if is_nil(original) do
          Application.delete_env(:zaq, Zaq.Ingestion)
        else
          Application.put_env(:zaq, Zaq.Ingestion, original)
        end
      end)

      :ok
    end

    test "passes embedding errors through from hybrid_search" do
      stub_embedding_failure()
      assert {:error, reason} = DocumentProcessor.query_extraction("query")
      assert is_binary(reason)
      assert String.contains?(reason, "API error")
    end

    test "returns token-limited results" do
      stub_embedding_success()
      stub_chunk_title_success()
      doc = create_document()

      dim = embedding_dimension()
      embedding = Pgvector.HalfVector.new(List.duplicate(0.1, dim))

      for i <- 1..3 do
        %Chunk{}
        |> Chunk.changeset(%{
          document_id: doc.id,
          content: "Chunk #{i} with some searchable content about testing.",
          chunk_index: i,
          section_path: ["Test"],
          metadata: %{section_type: :heading, section_level: 1, position: i},
          embedding: embedding
        })
        |> Repo.insert!()
      end

      assert {:ok, results} = DocumentProcessor.query_extraction("searchable content")
      assert is_list(results)

      Enum.each(results, fn r ->
        assert Map.has_key?(r, "content")
        assert Map.has_key?(r, "source")
        assert Map.has_key?(r, "rrf_score")
      end)
    end

    test "uses strict context-window boundary (equal is excluded)" do
      stub_embedding_success()
      doc = create_document(%{source: "strict-boundary.md"})

      dim = embedding_dimension()
      embedding = Pgvector.HalfVector.new(List.duplicate(0.1, dim))

      %Chunk{}
      |> Chunk.changeset(%{
        document_id: doc.id,
        content: "Boundary-only chunk with deterministic payload.",
        chunk_index: 1,
        section_path: ["Boundary"],
        metadata: %{section_type: :heading, section_level: 1, position: 1},
        embedding: embedding
      })
      |> Repo.insert!()

      boundary_tokens =
        %{
          "content" => "Boundary-only chunk with deterministic payload.",
          "source" => "strict-boundary.md",
          "rrf_score" => 1.0
        }
        |> Jason.encode!()
        |> TokenEstimator.estimate()

      Application.put_env(:zaq, Zaq.Ingestion, max_context_window: boundary_tokens)
      assert {:ok, []} = DocumentProcessor.query_extraction("deterministic payload")

      Application.put_env(:zaq, Zaq.Ingestion, max_context_window: boundary_tokens + 1)
      assert {:ok, [first | _]} = DocumentProcessor.query_extraction("deterministic payload")
      assert first["content"] == "Boundary-only chunk with deterministic payload."
    end
  end

  # ---------------------------------------------------------------------------
  # similarity_search/2 (integration)
  # ---------------------------------------------------------------------------

  describe "similarity_search/2" do
    test "returns chunks within distance threshold" do
      stub_embedding_success()
      doc = create_document()

      dim = embedding_dimension()
      embedding = Pgvector.HalfVector.new(List.duplicate(0.1, dim))

      %Chunk{}
      |> Chunk.changeset(%{
        document_id: doc.id,
        content: "Vector search test content.",
        chunk_index: 1,
        section_path: ["Test"],
        metadata: %{},
        embedding: embedding
      })
      |> Repo.insert!()

      assert {:ok, results} = DocumentProcessor.similarity_search("search test")
      assert is_list(results)
    end
  end

  # ---------------------------------------------------------------------------
  # similarity_search_count/1 (integration)
  # ---------------------------------------------------------------------------

  describe "similarity_search_count/1" do
    test "returns integer count" do
      stub_embedding_success()
      doc = create_document()

      dim = embedding_dimension()
      embedding = Pgvector.HalfVector.new(List.duplicate(0.1, dim))

      %Chunk{}
      |> Chunk.changeset(%{
        document_id: doc.id,
        content: "Countable content for hybrid search.",
        chunk_index: 1,
        section_path: [],
        metadata: %{},
        embedding: embedding
      })
      |> Repo.insert!()

      assert {:ok, count} =
               DocumentProcessor.similarity_search_count("countable content")

      assert is_integer(count)
      assert count >= 0
    end
  end

  # ---------------------------------------------------------------------------
  # hybrid_search/2 (integration)
  # ---------------------------------------------------------------------------

  describe "hybrid_search/2" do
    test "returns results with rrf_score" do
      stub_embedding_success()
      doc = create_document()

      dim = embedding_dimension()
      embedding = Pgvector.HalfVector.new(List.duplicate(0.1, dim))

      for i <- 1..5 do
        %Chunk{}
        |> Chunk.changeset(%{
          document_id: doc.id,
          content: "Hybrid search test chunk number #{i} with relevant keywords.",
          chunk_index: i,
          section_path: ["Search"],
          metadata: %{section_type: :heading, section_level: 1, position: i},
          embedding: embedding
        })
        |> Repo.insert!()
      end

      assert {:ok, results} =
               DocumentProcessor.hybrid_search("hybrid search keywords", nil, 5)

      assert is_list(results)

      Enum.each(results, fn r ->
        assert Map.has_key?(r, :chunk)
        assert Map.has_key?(r, :source)
        assert Map.has_key?(r, :rrf_score)
      end)
    end

    test "filters chunks by role_ids" do
      stub_embedding_success()
      doc = create_document()

      {:ok, role_a} =
        Zaq.Accounts.create_role(%{name: "dp_role_a_#{System.unique_integer([:positive])}"})

      {:ok, role_b} =
        Zaq.Accounts.create_role(%{name: "dp_role_b_#{System.unique_integer([:positive])}"})

      dim = embedding_dimension()
      embedding = Pgvector.HalfVector.new(List.duplicate(0.1, dim))

      %Chunk{}
      |> Chunk.changeset(%{
        document_id: doc.id,
        content: "role a chunk",
        chunk_index: 1,
        embedding: embedding,
        role_id: role_a.id
      })
      |> Repo.insert!()

      %Chunk{}
      |> Chunk.changeset(%{
        document_id: doc.id,
        content: "role b chunk",
        chunk_index: 2,
        embedding: embedding,
        role_id: role_b.id
      })
      |> Repo.insert!()

      %Chunk{}
      |> Chunk.changeset(%{
        document_id: doc.id,
        content: "untagged chunk",
        chunk_index: 3,
        embedding: embedding
      })
      |> Repo.insert!()

      {:ok, results} = DocumentProcessor.hybrid_search("chunk", [role_a.id])
      chunk_ids = Enum.map(results, & &1.chunk.role_id)

      # role_a chunks and nil-tagged chunks are visible; role_b is not
      refute role_b.id in chunk_ids
      assert Enum.any?(chunk_ids, &is_nil/1) or role_a.id in chunk_ids
    end

    test "nil role_ids returns all chunks" do
      stub_embedding_success()
      doc = create_document()

      {:ok, role} =
        Zaq.Accounts.create_role(%{name: "dp_role_nil_#{System.unique_integer([:positive])}"})

      dim = embedding_dimension()
      embedding = Pgvector.HalfVector.new(List.duplicate(0.1, dim))

      %Chunk{}
      |> Chunk.changeset(%{
        document_id: doc.id,
        content: "tagged chunk",
        chunk_index: 1,
        embedding: embedding,
        role_id: role.id
      })
      |> Repo.insert!()

      %Chunk{}
      |> Chunk.changeset(%{
        document_id: doc.id,
        content: "untagged chunk",
        chunk_index: 2,
        embedding: embedding
      })
      |> Repo.insert!()

      {:ok, results} = DocumentProcessor.hybrid_search("chunk", nil)
      assert length(results) >= 2
    end
  end
end
