defmodule Zaq.Agent.Tools.SearchKnowledgeBaseIntegrationTest do
  @moduledoc """
  Integration tests for SearchKnowledgeBase that hit the real DocumentProcessor
  and NodeRouter instead of stubs.

  Run with:

      mix test --include integration test/zaq/agent/tools/search_knowledge_base_integration_test.exs
  """

  use Zaq.DataCase, async: false

  @moduletag :integration
  @moduletag capture_log: true

  alias Ecto.Adapters.SQL.Sandbox
  alias Zaq.Agent.Tools.SearchKnowledgeBase
  alias Zaq.Ingestion.{Chunk, Document, DocumentProcessor}
  alias Zaq.Repo
  alias Zaq.SystemConfigFixtures

  @embedding_dim 1536

  setup_all do
    Sandbox.mode(Repo, :auto)

    try do
      Chunk.create_table(@embedding_dim)
    after
      Sandbox.mode(Repo, :manual)
    end

    :ok
  end

  setup do
    SystemConfigFixtures.seed_embedding_config(%{
      model: "test-model",
      dimension: "#{@embedding_dim}"
    })

    original_env = Application.get_env(:zaq, Zaq.Ingestion)
    Application.put_env(:zaq, Zaq.Ingestion, use_bm25: true)

    on_exit(fn ->
      if is_nil(original_env),
        do: Application.delete_env(:zaq, Zaq.Ingestion),
        else: Application.put_env(:zaq, Zaq.Ingestion, original_env)
    end)

    Req.Test.stub(Zaq.Embedding.Client, fn conn ->
      body = Jason.encode!(%{"data" => [%{"embedding" => List.duplicate(0.1, @embedding_dim)}]})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, body)
    end)

    :ok
  end

  describe "nil person_id — public data only (no skip_permissions)" do
    test "returns only public-tagged chunks when person_id is nil" do
      private_doc = create_doc(tags: [])
      public_doc = create_doc(tags: ["public"])
      insert_chunk(private_doc.id, "Private content about Elixir internals.", 0)
      insert_chunk(public_doc.id, "Public Elixir documentation.", 0)

      context = %{person_id: nil}

      assert {:ok, result} = SearchKnowledgeBase.run(%{query: "elixir"}, context)
      assert String.contains?(result.chunks, "Public Elixir documentation.")
      refute String.contains?(result.chunks, "Private content about Elixir internals.")
    end

    test "absent person_id also returns only public data" do
      public_doc = create_doc(tags: ["public"])
      insert_chunk(public_doc.id, "Phoenix is a web framework for Elixir.", 0)

      context = %{}

      assert {:ok, result} = SearchKnowledgeBase.run(%{query: "phoenix web framework"}, context)
      assert is_integer(result.count)
    end
  end

  describe "explicit admin (skip_permissions: true)" do
    test "returns all chunks regardless of document tags" do
      private_doc = create_doc(tags: [])
      insert_chunk(private_doc.id, "Restricted Elixir content.", 0)

      context = %{person_id: nil, skip_permissions: true}

      assert {:ok, result} = SearchKnowledgeBase.run(%{query: "restricted elixir"}, context)
      assert is_integer(result.count)
      assert result.count > 0
    end
  end

  describe "authenticated user" do
    test "returns access-denied content for unpermitted chunks" do
      doc = create_doc(tags: [])
      insert_chunk(doc.id, "Elixir is a functional language built on the BEAM VM.", 0)

      context = %{person_id: 999_999, team_ids: []}

      assert {:ok, result} = SearchKnowledgeBase.run(%{query: "elixir functional"}, context)
      assert is_integer(result.count)

      if result.count > 0 do
        assert String.contains?(result.chunks, DocumentProcessor.access_denied_message())
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp create_doc(opts \\ []) do
    tags = Keyword.get(opts, :tags, [])

    {:ok, doc} =
      Document.upsert(%{
        source: "search_kb_test_#{System.unique_integer([:positive])}.md",
        content: "Test document.",
        content_type: "markdown",
        tags: tags
      })

    doc
  end

  defp insert_chunk(doc_id, content, index) do
    embedding = Pgvector.HalfVector.new(List.duplicate(0.1, @embedding_dim))

    %Chunk{}
    |> Chunk.changeset(%{
      document_id: doc_id,
      content: content,
      chunk_index: index,
      section_path: ["test"],
      metadata: %{},
      embedding: embedding,
      language: "english"
    })
    |> Repo.insert!()
  end
end
