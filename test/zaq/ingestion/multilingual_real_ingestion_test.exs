defmodule Zaq.Ingestion.MultilingualRealIngestionTest do
  @moduledoc """
  Runs four real Markdown fixtures through file read, layout chunking, Lingua,
  external embedding HTTP, persistence and document progress materialization.
  Only the external embedding HTTP response is stubbed.
  """

  use Zaq.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox

  alias Zaq.Ingestion.{
    Chunk,
    Document,
    DocumentIngestionSummary,
    DocumentProcessor,
    FTSBackend,
    IngestChunkJob,
    IngestChunkWorker,
    IngestJob
  }

  alias Zaq.Repo
  alias Zaq.SystemConfigFixtures
  alias Zaq.TestSupport.OpenAIStub

  @dimension 1536
  @fixture_dir Path.expand("../../fixtures/multilingual_ingestion", __DIR__)

  setup_all do
    Sandbox.mode(Repo, :auto)

    try do
      Chunk.create_table(@dimension)
    after
      Sandbox.mode(Repo, :manual)
    end

    :ok
  end

  setup do
    FTSBackend.reset_cache()
    :persistent_term.put({FTSBackend, :backend}, FTSBackend.Native)
    SystemConfigFixtures.seed_embedding_config(%{model: "test-model", dimension: "#{@dimension}"})

    original_processor = Application.get_env(:zaq, :document_processor)
    Application.put_env(:zaq, :document_processor, DocumentProcessor)

    Req.Test.stub(Zaq.Embedding.Client, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, OpenAIStub.embedding_response(@dimension) |> Jason.encode!())
    end)

    on_exit(fn ->
      FTSBackend.reset_cache()

      if is_nil(original_processor),
        do: Application.delete_env(:zaq, :document_processor),
        else: Application.put_env(:zaq, :document_processor, original_processor)
    end)

    :ok
  end

  for {name, expected} <- [
        {"english", ~w(english)},
        {"english_french", ~w(english french)},
        {"arabic", ~w(arabic)},
        {"english_french_arabic", ~w(arabic english french)}
      ] do
    test "#{name} Markdown fixture persists correct chunk languages and document metadata" do
      fixture = Path.join(@fixture_dir, unquote(name) <> ".md")

      assert {:ok, document, report} = DocumentProcessor.process_single_file_with_report(fixture)
      chunks = Chunk.list_by_document(document.id)
      stored = Repo.get!(Document, document.id)
      summary = stored.metadata["ingestion"]

      assert chunks != []
      assert report.failed_chunks == 0
      assert report.ingested_chunks == length(chunks)
      assert Enum.sort(Enum.uniq(Enum.map(chunks, & &1.language))) == unquote(expected)
      assert summary["detected_languages"] == unquote(expected)
      assert summary["indexed_languages"] == unquote(expected)
      assert summary["total_chunks_detected"] == length(chunks)
      assert summary["total_chunks_indexed"] == length(chunks)
      assert summary["total_chunks_simple_indexed"] == 0
      assert summary["errors"] == []
      assert stored.source == document.source
      assert stored.content == File.read!(fixture)

      for chunk <- chunks do
        assert chunk.document_id == document.id
        assert chunk.section_path != []
        assert chunk.metadata["search_configuration"] == chunk.language

        assert {:ok, %Postgrex.Result{rows: [[true]]}} =
                 Repo.query(
                   "SELECT content_tsv = to_tsvector($1::text::regconfig, content) FROM chunks WHERE id = $2",
                   ["pg_catalog.#{chunk.language}", chunk.id]
                 )
      end
    end
  end

  test "the real chunk worker indexes multilingual payloads and finalizes document metadata" do
    fixture = Path.join(@fixture_dir, "english_french_arabic.md")
    assert {:ok, document, payloads} = DocumentProcessor.prepare_file_chunks(fixture)

    {:ok, job} =
      %IngestJob{}
      |> IngestJob.changeset(%{
        file_path: fixture,
        document_id: document.id,
        status: "processing"
      })
      |> Repo.insert()

    IngestChunkJob.upsert_many(job.id, document.id, payloads)
    assert :ok = DocumentIngestionSummary.refresh(job, new_run: true)

    for {_payload, index} <- payloads do
      chunk_job = Repo.get_by!(IngestChunkJob, ingest_job_id: job.id, chunk_index: index)

      assert :ok =
               IngestChunkWorker.perform(%Oban.Job{
                 args: %{"job_id" => job.id, "chunk_job_id" => chunk_job.id},
                 attempt: 1,
                 max_attempts: 5
               })
    end

    stored = Repo.get!(Document, document.id)
    chunks = Chunk.list_by_document(document.id)
    summary = stored.metadata["ingestion"]

    assert Repo.get!(IngestJob, job.id).status == "completed"
    assert summary["status"] == "completed"
    assert summary["detected_languages"] == ~w(arabic english french)
    assert summary["indexed_languages"] == ~w(arabic english french)
    assert summary["total_chunks_detected"] == length(payloads)
    assert summary["total_chunks_indexed"] == length(chunks)
    assert summary["total_chunks_simple_indexed"] == 0
    assert Enum.sort(Enum.uniq(Enum.map(chunks, & &1.language))) == ~w(arabic english french)

    for chunk <- chunks do
      assert chunk.document_id == stored.id
      assert chunk.section_path != []
      assert chunk.metadata["search_configuration"] == chunk.language
    end
  end

  test "a real embedding HTTP failure records the unindexed language and retry repairs metadata" do
    fixture = Path.join(@fixture_dir, "english_french.md")

    Req.Test.stub(Zaq.Embedding.Client, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)

      if String.contains?(Jason.decode!(raw)["input"], "Instructions de maintenance") do
        Plug.Conn.send_resp(conn, 503, "embedding unavailable")
      else
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, OpenAIStub.embedding_response(@dimension) |> Jason.encode!())
      end
    end)

    assert {:ok, document, report} = DocumentProcessor.process_single_file_with_report(fixture)
    assert report.failed_chunks == 1
    assert [failed_index] = report.failed_chunk_indices
    summary = Repo.get!(Document, document.id).metadata["ingestion"]
    assert summary["total_chunks_detected"] == 2
    assert summary["total_chunks_indexed"] == 1
    assert summary["total_chunks_simple_indexed"] == 0
    assert summary["detected_languages"] == ~w(english french)
    assert summary["indexed_languages"] == ["english"]

    assert [%{"chunk_index" => ^failed_index, "language" => "french", "code" => "chunk_failed"}] =
             summary["errors"]

    Req.Test.stub(Zaq.Embedding.Client, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, OpenAIStub.embedding_response(@dimension) |> Jason.encode!())
    end)

    assert {:ok, _document, retry_report} =
             DocumentProcessor.process_single_file_with_report(fixture,
               reset_chunks: false,
               retry_chunk_indices: [failed_index]
             )

    assert retry_report.failed_chunks == 0
    assert summary = Repo.get!(Document, document.id).metadata["ingestion"]
    assert summary["total_chunks_indexed"] == 2
    assert summary["indexed_languages"] == ~w(english french)
    assert summary["errors"] == []
  end
end
