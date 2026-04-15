defmodule Zaq.Ingestion.IngestWorkerTest do
  use Zaq.DataCase, async: false

  @moduletag capture_log: true

  import Mox

  alias Zaq.Ingestion.{Chunk, Document, IngestChunkJob, IngestJob, IngestWorker}
  alias Zaq.Repo
  alias Zaq.SystemConfigFixtures

  defmodule ChunkPipelineProcessor do
    alias Zaq.Ingestion.{Chunk, DocumentChunker}

    def prepare_file_chunks(_path) do
      document_id = :persistent_term.get({__MODULE__, :document_id})

      {:ok, %{id: document_id},
       [
         {payload("a", 1), 1},
         {payload("b", 2), 2}
       ]}
    end

    def store_chunk_with_metadata(
          %DocumentChunker.Chunk{} = chunk,
          document_id,
          chunk_index
        ) do
      Chunk.create(%{
        document_id: document_id,
        content: chunk.content,
        chunk_index: chunk_index
      })
    end

    defp payload(content, idx) do
      %{
        "id" => "chunk-#{idx}",
        "section_id" => "sec-#{idx}",
        "content" => content,
        "section_path" => ["Sec #{idx}"],
        "tokens" => 10,
        "metadata" => %{"section_type" => "heading", "section_level" => 1, "position" => idx}
      }
    end
  end

  setup do
    SystemConfigFixtures.seed_embedding_config(%{model: "test-model", dimension: "1536"})
    Mox.set_mox_global()
    :ok
  end

  setup :verify_on_exit!

  defp create_job(attrs \\ %{}) do
    %IngestJob{}
    |> IngestJob.changeset(
      Map.merge(%{file_path: "docs/test.md", status: "pending", mode: "async"}, attrs)
    )
    |> Repo.insert!()
  end

  defp create_document(attrs \\ %{}) do
    default = %{source: "worker-test-#{System.unique_integer([:positive])}.md", content: "# Test"}

    %Document{}
    |> Document.changeset(Map.merge(default, attrs))
    |> Repo.insert!()
  end

  describe "perform/1" do
    test "sets status to completed on success" do
      job = create_job()
      Zaq.Ingestion.subscribe()

      doc = create_document()

      %Chunk{}
      |> Chunk.changeset(%{document_id: doc.id, content: "first", chunk_index: 1})
      |> Repo.insert!()

      %Chunk{}
      |> Chunk.changeset(%{document_id: doc.id, content: "second", chunk_index: 2})
      |> Repo.insert!()

      expect(Zaq.DocumentProcessorMock, :process_single_file, fn _path ->
        {:ok, doc}
      end)

      assert :ok =
               IngestWorker.perform(%Oban.Job{
                 args: %{"job_id" => job.id},
                 attempt: 1,
                 max_attempts: 3
               })

      job_id = job.id

      updated = Repo.get!(IngestJob, job.id)
      assert updated.status == "completed"
      assert updated.chunks_count == 2
      assert updated.document_id == doc.id
      assert updated.started_at != nil
      assert updated.completed_at != nil

      assert_receive {:job_updated, %{id: ^job_id, status: "processing"}}
      assert_receive {:job_updated, %{id: ^job_id, status: "completed", chunks_count: 2}}
    end

    test "sets status to failed on error" do
      job = create_job()
      Zaq.Ingestion.subscribe()

      expect(Zaq.DocumentProcessorMock, :process_single_file, fn _path ->
        {:error, :parse_error}
      end)

      assert {:cancel, :parse_error} =
               IngestWorker.perform(%Oban.Job{
                 args: %{"job_id" => job.id},
                 attempt: 3,
                 max_attempts: 3
               })

      job_id = job.id

      updated = Repo.get!(IngestJob, job.id)
      assert updated.status == "failed"
      assert updated.error =~ "parse_error"
      assert updated.completed_at != nil

      assert_receive {:job_updated, %{id: ^job_id, status: "processing"}}
      assert_receive {:job_updated, %{id: ^job_id, status: "failed"}}
    end

    test "uses chunk child-job pipeline when processor supports prepare_file_chunks/3" do
      original_processor = Application.get_env(:zaq, :document_processor)

      on_exit(fn ->
        _ = :persistent_term.erase({ChunkPipelineProcessor, :document_id})

        if is_nil(original_processor) do
          Application.delete_env(:zaq, :document_processor)
        else
          Application.put_env(:zaq, :document_processor, original_processor)
        end
      end)

      Application.put_env(:zaq, :document_processor, ChunkPipelineProcessor)
      document = create_document()
      :persistent_term.put({ChunkPipelineProcessor, :document_id}, document.id)

      job = create_job()

      assert :ok =
               IngestWorker.perform(%Oban.Job{
                 args: %{"job_id" => job.id},
                 attempt: 1,
                 max_attempts: 3
               })

      updated = Repo.get!(IngestJob, job.id)
      assert updated.total_chunks == 2
      assert updated.ingested_chunks == 2
      assert updated.status == "completed"

      chunk_jobs = Repo.all(from(c in IngestChunkJob, where: c.ingest_job_id == ^job.id))
      assert length(chunk_jobs) == 2
      assert Enum.all?(chunk_jobs, &(&1.status == "completed"))
    end

    test "keeps job pending when attempt is below max" do
      job = create_job()
      Zaq.Ingestion.subscribe()

      expect(Zaq.DocumentProcessorMock, :process_single_file, fn _path ->
        {:error, "temporary failure"}
      end)

      assert {:error, "temporary failure"} =
               IngestWorker.perform(%Oban.Job{
                 args: %{"job_id" => job.id},
                 attempt: 1,
                 max_attempts: 3
               })

      job_id = job.id

      updated = Repo.get!(IngestJob, job.id)
      assert updated.status == "pending"
      assert updated.error == "Attempt 1 failed: temporary failure"

      assert_receive {:job_updated, %{id: ^job_id, status: "processing"}}
      assert_receive {:job_updated, %{id: ^job_id, status: "pending"}}
    end

    test "uses unresolved path when resolve_path fails" do
      job = create_job(%{file_path: "../../bad.md"})

      expect(Zaq.DocumentProcessorMock, :process_single_file, fn path ->
        assert path == "../../bad.md"
        {:error, :missing}
      end)

      assert {:error, :missing} =
               IngestWorker.perform(%Oban.Job{
                 args: %{"job_id" => job.id},
                 attempt: 1,
                 max_attempts: 3
               })
    end

    test "resolves path against volume_name when job has one" do
      vol_dir =
        Path.join(System.tmp_dir!(), "zaq_worker_vol_#{System.unique_integer([:positive])}")

      File.mkdir_p!(vol_dir)

      original = Application.get_env(:zaq, Zaq.Ingestion)

      on_exit(fn ->
        if is_nil(original) do
          Application.delete_env(:zaq, Zaq.Ingestion)
        else
          Application.put_env(:zaq, Zaq.Ingestion, original)
        end
      end)

      Application.put_env(:zaq, Zaq.Ingestion, volumes: %{"myvol" => vol_dir})

      job = create_job(%{file_path: "report.md", volume_name: "myvol"})
      expected_path = Path.join(vol_dir, "report.md")

      expect(Zaq.DocumentProcessorMock, :process_single_file, fn path ->
        assert path == expected_path
        {:ok, create_document()}
      end)

      assert :ok =
               IngestWorker.perform(%Oban.Job{
                 args: %{"job_id" => job.id},
                 attempt: 1,
                 max_attempts: 3
               })
    end

    test "converts crashes to retries" do
      job = create_job()

      expect(Zaq.DocumentProcessorMock, :process_single_file, fn _path ->
        raise "boom"
      end)

      assert {:error, "boom"} =
               IngestWorker.perform(%Oban.Job{
                 args: %{"job_id" => job.id},
                 attempt: 1,
                 max_attempts: 3
               })

      updated = Repo.get!(IngestJob, job.id)
      assert updated.status == "pending"
      assert updated.error == "Attempt 1 failed: boom"
    end

    test "backoff scales linearly by attempt" do
      assert IngestWorker.backoff(%Oban.Job{attempt: 1}) == 5
      assert IngestWorker.backoff(%Oban.Job{attempt: 3}) == 15
    end
  end
end
