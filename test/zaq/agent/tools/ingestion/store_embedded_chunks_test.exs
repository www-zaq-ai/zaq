defmodule Zaq.Agent.Tools.Ingestion.StoreEmbeddedChunksTest do
  use Zaq.DataCase, async: false

  alias Zaq.AccountsFixtures
  alias Zaq.Agent.Tools.Ingestion.{ChunkContent, StoreEmbeddedChunks}
  alias Zaq.Contracts.Record
  alias Zaq.Contracts.Record.Provenance
  alias Zaq.Event
  alias Zaq.Ingestion.{Api, Chunk}
  alias Zaq.NodeRouterMock
  alias Zaq.SystemConfigFixtures

  import Mox

  @dimension 1536

  setup :verify_on_exit!

  setup do
    SystemConfigFixtures.seed_embedding_config(%{model: "storage-model", dimension: @dimension})
    user = AccountsFixtures.super_admin_fixture(%{must_change_password: false})

    record = %Record{
      id: "storage-fixture",
      kind: :file,
      name: "source.pdf",
      permissions: [],
      attributes: %{"provider" => "google_drive", "config_id" => "42"}
    }

    {:ok, record} = Provenance.seal(record, %{"provider" => "google_drive", "config_id" => 42})
    %{context: %{actor: %{user_id: user.id}, node_router: NodeRouterMock}, record: record}
  end

  test "stores verbatim chunks, rejects individual invalid vectors, and retries only failures", %{
    context: context,
    record: record
  } do
    markdown = """
    <!-- page: 4 -->
    # Résultats
    Ce texte est écrit en français et doit rester intact dans le document.

    # Final
    This source text belongs to the second chunk.
    """

    {:ok, %{chunks: [first, second]}} = Jido.Exec.run(ChunkContent, %{content: markdown}, %{})
    attempt = Ecto.UUID.generate()
    start = %{attempt_id: attempt, record: record, markdown: markdown}
    valid = item(first, List.duplicate(0.1, @dimension))
    underflow = item(second, List.duplicate(1.0e-12, @dimension))

    expect_role()

    expect(NodeRouterMock, :dispatch, fn event ->
      assert event.opts[:action] == :data_source_get_file
      %{event | response: {:ok, %{record: record}}}
    end)

    assert {:ok,
            %{
              document_id: document_id,
              attempt_id: ^attempt,
              results: [
                %{chunk_index: 1, status: "stored"},
                %{chunk_index: 2, status: "error", error: "zero_norm_embedding"}
              ]
            }} = execute(Map.put(start, :items, [valid, underflow]), context)

    assert [stored] = Chunk.list_by_document(document_id)
    assert stored.content == first.content
    refute stored.content == first.embedding_input
    assert stored.section_path == first.section_path
    assert stored.metadata["start"] == first.metadata.start
    assert is_binary(stored.language)
    refute Map.has_key?(stored.metadata, "embedding_input")

    expect_role()

    assert {:ok, %{results: [%{status: "already_stored"}, %{chunk_index: 2, status: "stored"}]}} =
             execute(
               %{
                 attempt_id: attempt,
                 items: [valid, item(second, List.duplicate(0.2, @dimension))]
               },
               context
             )

    assert [^stored, %{content: content}] = Chunk.list_by_document(document_id)
    assert content == second.content
  end

  test "denies a valid request supplied with only an actorless permission bypass", %{
    record: record
  } do
    chunk = %{chunk_index: 1, content: "text", section_path: [], metadata: %{}}
    expect_role()

    assert {:error, %Jido.Action.Error.ExecutionFailureError{details: %{reason: :unauthorized}}} =
             execute(
               %{
                 attempt_id: Ecto.UUID.generate(),
                 record: record,
                 markdown: "text",
                 items: [item(chunk, List.duplicate(0.1, @dimension))]
               },
               %{skip_permissions: true, node_router: NodeRouterMock}
             )
  end

  test "reports a mismatched chunk association, model, dimension or value per item", %{
    context: context,
    record: record
  } do
    chunk = %{chunk_index: 1, content: "text", section_path: [], metadata: %{}}
    vector = List.duplicate(0.1, @dimension)
    base = item(chunk, vector)

    invalid = [
      %{chunk_index: 2},
      %{model: "another-model"},
      %{vector: [0.1]},
      %{vector: [70_000 | tl(vector)]}
    ]

    items =
      invalid
      |> Enum.with_index(1)
      |> Enum.map(fn {fields, index} ->
        %{
          chunk: %{chunk | chunk_index: index},
          embedding: base.embedding |> Map.put(:chunk_index, index) |> Map.merge(fields)
        }
      end)

    expect_role()

    expect(NodeRouterMock, :dispatch, fn event ->
      %{event | response: {:ok, %{record: record}}}
    end)

    assert {:ok, %{document_id: id, results: results}} =
             execute(
               %{
                 attempt_id: Ecto.UUID.generate(),
                 record: record,
                 markdown: "text",
                 items: items
               },
               context
             )

    assert Enum.map(results, &{&1.chunk_index, &1.error}) == [
             {1, "embedding_index_mismatch"},
             {2, "embedding_model_mismatch"},
             {3, "dimension_mismatch"},
             {4, "invalid_vector"}
           ]

    assert Chunk.list_by_document(id) == []
  end

  defp item(chunk, vector) do
    %{
      chunk: chunk,
      embedding: %{
        chunk_index: chunk.chunk_index,
        dimension: @dimension,
        model: "storage-model",
        vector: vector
      }
    }
  end

  defp expect_role do
    expect(NodeRouterMock, :dispatch, fn %Event{} = event ->
      assert event.opts[:confidential]
      Api.handle_event(event, :store_embedded_chunks, %{node_router: NodeRouterMock})
    end)
  end

  defp execute(input, context), do: Jido.Exec.run(StoreEmbeddedChunks, input, context)
end
