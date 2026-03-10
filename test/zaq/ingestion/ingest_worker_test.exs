defmodule Zaq.Ingestion.IngestWorkerTest do
  use Zaq.DataCase, async: false

  import Mox

  alias Zaq.Ingestion.{Chunk, Document, IngestJob, IngestWorker}
  alias Zaq.Repo

  setup do
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
