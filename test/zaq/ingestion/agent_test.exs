defmodule Zaq.Ingestion.AgentTest do
  @moduledoc """
  Integration tests for `Zaq.Ingestion.Agent`.

  These tests run the full pipeline end-to-end using a real document processor mock
  so that each mode (`:full`, `:upload_only`, `:from_converted`) is exercised.
  """

  use Zaq.DataCase, async: false

  @moduletag capture_log: true

  import Mox

  alias Zaq.Ingestion.{Agent, Chunk, Document, IngestJob}
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

    # Default stub: ConvertToMarkdown uses the mock, which reads .md files directly.
    stub(Zaq.DocumentProcessorMock, :read_as_markdown, fn path -> File.read(path) end)

    :ok
  end

  setup :verify_on_exit!

  defp create_job(file_path, attrs \\ %{}) do
    %IngestJob{}
    |> IngestJob.changeset(
      Map.merge(%{file_path: file_path, status: "pending", mode: "async"}, attrs)
    )
    |> Repo.insert!()
  end

  defp create_document(source) do
    %Document{}
    |> Document.changeset(%{source: source, content: "# Test"})
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

  defp tmp_md_file(content \\ "# Hello\n\nWorld.") do
    path = Path.join(System.tmp_dir!(), "agent_test_#{System.unique_integer([:positive])}.md")
    File.write!(path, content)
    on_exit(fn -> File.rm(path) end)
    path
  end

  # -------------------------------------------------------------------------
  # Scenario 1: Full pipeline run
  # -------------------------------------------------------------------------

  describe "run/1 — full pipeline" do
    test "returns {:ok, job} with status completed when all chunks succeed" do
      file_path = tmp_md_file()
      job = create_job(file_path)
      doc = create_document("agent-full-#{System.unique_integer([:positive])}.md")

      payloads = [make_payload("chunk a", 0), make_payload("chunk b", 1)]

      expect(Zaq.DocumentProcessorMock, :prepare_file_chunks, fn _path ->
        {:ok, doc, payloads}
      end)

      expect(Zaq.DocumentProcessorMock, :store_chunk_with_metadata, 2, fn chunk, _doc_id, idx ->
        Chunk.create(%{document_id: doc.id, content: chunk.content, chunk_index: idx})
      end)

      Application.put_env(:zaq, :document_processor, Zaq.DocumentProcessorMock)

      assert {:ok, updated} = Agent.run(job)
      assert updated.status == "completed"
      assert updated.ingested_chunks == 2
      assert updated.failed_chunks == 0
      assert updated.total_chunks == 2
    end

    test "returns {:ok, job} with status completed_with_errors when some chunks fail" do
      file_path = tmp_md_file()
      job = create_job(file_path)
      doc = create_document("agent-cwe-#{System.unique_integer([:positive])}.md")

      payloads = [make_payload("ok", 0), make_payload("fail", 1)]

      expect(Zaq.DocumentProcessorMock, :prepare_file_chunks, fn _path ->
        {:ok, doc, payloads}
      end)

      # Use stub since async ordering is non-deterministic — chunk 0 succeeds, chunk 1 fails.
      stub(Zaq.DocumentProcessorMock, :store_chunk_with_metadata, fn chunk, _doc_id, idx ->
        if idx == 0 do
          Chunk.create(%{document_id: doc.id, content: chunk.content, chunk_index: idx})
        else
          {:error, "embedding failed"}
        end
      end)

      Application.put_env(:zaq, :document_processor, Zaq.DocumentProcessorMock)

      assert {:ok, updated} = Agent.run(job)
      assert updated.status == "completed_with_errors"
      assert updated.failed_chunks == 1
    end

    test "returns {:error, job} with status failed when chunking fails" do
      file_path = tmp_md_file()
      job = create_job(file_path)

      expect(Zaq.DocumentProcessorMock, :prepare_file_chunks, fn _path ->
        {:error, "chunking error"}
      end)

      Application.put_env(:zaq, :document_processor, Zaq.DocumentProcessorMock)

      assert {:error, updated} = Agent.run(job)
      assert updated.status == "failed"
      assert updated.error =~ "chunking error"
    end
  end

  # -------------------------------------------------------------------------
  # Scenario 2: Upload-only — stops at `converted`, no chunks created
  # -------------------------------------------------------------------------

  describe "run/2 — upload_only mode" do
    test "sets job status to converted and creates no chunks" do
      file_path = tmp_md_file()
      job = create_job(file_path)

      # No processor calls expected — pipeline stops after ConvertToMarkdown
      Application.put_env(:zaq, :document_processor, Zaq.DocumentProcessorMock)

      assert {:ok, updated} = Agent.run(job, upload_only: true)
      assert updated.status == "converted"
      assert Chunk.count_by_document(updated.document_id || -1) == 0
    end
  end

  # -------------------------------------------------------------------------
  # Scenario 3: Resume from converted — skips upload/conversion
  # -------------------------------------------------------------------------

  describe "run/1 — from_converted mode" do
    test "skips UploadFile and ConvertToMarkdown when sidecar exists" do
      base = Path.join(System.tmp_dir!(), "agent_resume_#{System.unique_integer([:positive])}")
      pdf_path = base <> ".pdf"
      md_path = base <> ".md"

      File.write!(pdf_path, "fake pdf")
      File.write!(md_path, "# Already Converted")

      on_exit(fn ->
        File.rm(pdf_path)
        File.rm(md_path)
      end)

      job = create_job(pdf_path)
      doc = create_document("agent-resume-#{System.unique_integer([:positive])}.md")
      payloads = [make_payload("chunk from sidecar", 0)]

      # Only ChunkDocument → EmbedChunks → AddToRag run; no conversion
      expect(Zaq.DocumentProcessorMock, :prepare_file_chunks, fn _path ->
        {:ok, doc, payloads}
      end)

      expect(Zaq.DocumentProcessorMock, :store_chunk_with_metadata, fn chunk, _doc_id, idx ->
        Chunk.create(%{document_id: doc.id, content: chunk.content, chunk_index: idx})
      end)

      Application.put_env(:zaq, :document_processor, Zaq.DocumentProcessorMock)

      assert {:ok, updated} = Agent.run(job)
      assert updated.status == "completed"
      assert updated.ingested_chunks == 1
    end
  end
end
