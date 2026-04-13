defmodule Zaq.Ingestion.Actions.ChunkDocumentTest do
  use Zaq.DataCase, async: false

  import Mox

  alias Zaq.Ingestion.Actions.ChunkDocument

  setup :verify_on_exit!

  setup do
    original = Application.get_env(:zaq, :document_processor)

    on_exit(fn ->
      if is_nil(original),
        do: Application.delete_env(:zaq, :document_processor),
        else: Application.put_env(:zaq, :document_processor, original)
    end)

    Mox.set_mox_global()
    :ok
  end

  describe "run/2" do
    test "returns document_id and indexed_payloads on success" do
      doc_id = Ecto.UUID.generate()

      payloads = [
        {%{
           "content" => "chunk a",
           "id" => "c1",
           "section_id" => "s1",
           "section_path" => [],
           "tokens" => 5,
           "metadata" => %{}
         }, 0},
        {%{
           "content" => "chunk b",
           "id" => "c2",
           "section_id" => "s2",
           "section_path" => [],
           "tokens" => 5,
           "metadata" => %{}
         }, 1}
      ]

      expect(Zaq.DocumentProcessorMock, :prepare_file_chunks, fn _path ->
        {:ok, %{id: doc_id}, payloads}
      end)

      Application.put_env(:zaq, :document_processor, Zaq.DocumentProcessorMock)

      assert {:ok, result} = ChunkDocument.run(%{file_path: "/some/file.md"}, %{})
      assert result.document_id == doc_id
      assert length(result.indexed_payloads) == 2
    end

    test "returns {:error, reason} when processor fails" do
      expect(Zaq.DocumentProcessorMock, :prepare_file_chunks, fn _path ->
        {:error, "chunking failed"}
      end)

      Application.put_env(:zaq, :document_processor, Zaq.DocumentProcessorMock)

      assert {:error, "chunking failed"} = ChunkDocument.run(%{file_path: "/bad/path.md"}, %{})
    end
  end
end
