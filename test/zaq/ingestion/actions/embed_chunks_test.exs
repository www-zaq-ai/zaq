defmodule Zaq.Ingestion.Actions.EmbedChunksTest do
  use Zaq.DataCase, async: false

  import Mox

  alias Zaq.Ingestion.Actions.EmbedChunks
  alias Zaq.Ingestion.{Chunk, Document}
  alias Zaq.Repo
  alias Zaq.System.EmbeddingConfig

  setup do
    changeset =
      EmbeddingConfig.changeset(%EmbeddingConfig{}, %{
        endpoint: "http://localhost:11434/v1",
        model: "test-model",
        dimension: "1536"
      })

    {:ok, _} = Zaq.System.save_embedding_config(changeset)

    original = Application.get_env(:zaq, :document_processor)

    on_exit(fn ->
      if is_nil(original),
        do: Application.delete_env(:zaq, :document_processor),
        else: Application.put_env(:zaq, :document_processor, original)
    end)

    Mox.set_mox_global()
    :ok
  end

  setup :verify_on_exit!

  defp create_document do
    %Document{}
    |> Document.changeset(%{
      source: "embed-test-#{System.unique_integer([:positive])}.md",
      content: "# Test"
    })
    |> Repo.insert!()
  end

  defp make_payload(content, idx) do
    {%{
       "id" => "c#{idx}",
       "section_id" => "s#{idx}",
       "content" => content,
       "section_path" => [],
       "tokens" => 5,
       "metadata" => %{}
     }, idx}
  end

  describe "run/2" do
    test "returns ingested_count and failed_count on all success" do
      doc = create_document()
      payloads = [make_payload("hello", 0), make_payload("world", 1)]

      expect(Zaq.DocumentProcessorMock, :store_chunk_with_metadata, 2, fn chunk, _doc_id, idx ->
        Chunk.create(%{document_id: doc.id, content: chunk.content, chunk_index: idx})
      end)

      Application.put_env(:zaq, :document_processor, Zaq.DocumentProcessorMock)

      assert {:ok, result} =
               EmbedChunks.run(%{document_id: doc.id, indexed_payloads: payloads}, %{})

      assert result.ingested_count == 2
      assert result.failed_count == 0
      assert result.document_id == doc.id
    end

    test "counts failed chunks when some embeddings fail" do
      doc = create_document()
      payloads = [make_payload("ok", 0), make_payload("fail", 1)]

      stub(Zaq.DocumentProcessorMock, :store_chunk_with_metadata, fn chunk, _doc_id, idx ->
        if idx == 0 do
          Chunk.create(%{document_id: doc.id, content: chunk.content, chunk_index: idx})
        else
          {:error, "embedding failed"}
        end
      end)

      Application.put_env(:zaq, :document_processor, Zaq.DocumentProcessorMock)

      assert {:ok, result} =
               EmbedChunks.run(%{document_id: doc.id, indexed_payloads: payloads}, %{})

      assert result.ingested_count + result.failed_count == 2
    end

    test "clears existing chunks before embedding" do
      doc = create_document()

      {:ok, _} = Chunk.create(%{document_id: doc.id, content: "old chunk", chunk_index: 0})

      payloads = [make_payload("new chunk", 0)]

      expect(Zaq.DocumentProcessorMock, :store_chunk_with_metadata, fn chunk, _doc_id, idx ->
        Chunk.create(%{document_id: doc.id, content: chunk.content, chunk_index: idx})
      end)

      Application.put_env(:zaq, :document_processor, Zaq.DocumentProcessorMock)

      assert {:ok, %{ingested_count: 1}} =
               EmbedChunks.run(%{document_id: doc.id, indexed_payloads: payloads}, %{})

      # Only the new chunk should exist
      assert Chunk.count_by_document(doc.id) == 1
    end

    test "returns {:ok, ...} with ingested_count 0 for empty payloads" do
      doc = create_document()

      Application.put_env(:zaq, :document_processor, Zaq.DocumentProcessorMock)

      assert {:ok, result} = EmbedChunks.run(%{document_id: doc.id, indexed_payloads: []}, %{})
      assert result.ingested_count == 0
      assert result.failed_count == 0
    end
  end
end
