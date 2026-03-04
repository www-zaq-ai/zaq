defmodule Zaq.IngestionTest do
  use Zaq.DataCase, async: true

  import Mox

  alias Zaq.Ingestion
  alias Zaq.Ingestion.IngestJob
  alias Zaq.Repo

  setup do
    Mox.set_mox_global()
    :ok
  end

  defp create_job(attrs \\ %{}) do
    %IngestJob{}
    |> IngestJob.changeset(
      Map.merge(%{file_path: "docs/test.md", status: "pending", mode: "async"}, attrs)
    )
    |> Repo.insert!()
  end

  describe "ingest_file/2" do
    test "creates a job and enqueues worker in async mode" do
      expect(Zaq.DocumentProcessorMock, :process_single_file, fn "docs/file.md" ->
        {:ok, %{chunks_count: 2, document_id: nil}}
      end)

      assert {:ok, job} = Ingestion.ingest_file("docs/file.md", :async)
      assert job.status == "pending"
      assert job.mode == "async"
      assert job.file_path == "docs/file.md"
    end

    test "creates a job and processes inline" do
      expect(Zaq.DocumentProcessorMock, :process_single_file, fn "docs/file.md" ->
        {:ok, %{chunks_count: 3, document_id: nil}}
      end)

      assert {:ok, job} = Ingestion.ingest_file("docs/file.md", :inline)
      assert job.status == "completed"
      assert job.mode == "inline"
    end
  end

  describe "list_jobs/1" do
    test "returns all jobs ordered by inserted_at desc" do
      j1 = create_job(%{file_path: "a.md"})
      j2 = create_job(%{file_path: "b.md"})

      jobs = Ingestion.list_jobs()
      ids = Enum.map(jobs, & &1.id)

      assert j2.id in ids
      assert j1.id in ids
    end

    test "filters by status" do
      create_job(%{file_path: "a.md", status: "pending"})
      create_job(%{file_path: "b.md", status: "completed"})

      jobs = Ingestion.list_jobs(status: "pending")
      assert length(jobs) == 1
      assert hd(jobs).status == "pending"
    end
  end

  describe "get_job/1" do
    test "returns job by id" do
      job = create_job()
      assert Ingestion.get_job(job.id).id == job.id
    end

    test "returns nil for unknown id" do
      assert Ingestion.get_job(Ecto.UUID.generate()) == nil
    end
  end

  describe "retry_job/1" do
    test "retries a failed job" do
      job = create_job(%{status: "failed", error: "something broke"})

      expect(Zaq.DocumentProcessorMock, :process_single_file, fn "docs/test.md" ->
        {:ok, %{chunks_count: 1, document_id: nil}}
      end)

      assert {:ok, retried} = Ingestion.retry_job(job.id)
      assert retried.status == "pending"
      assert retried.error == nil
    end

    test "returns error if job is not failed" do
      job = create_job(%{status: "completed"})
      assert {:error, :not_failed} = Ingestion.retry_job(job.id)
    end

    test "returns error if job not found" do
      assert {:error, :not_found} = Ingestion.retry_job(Ecto.UUID.generate())
    end
  end

  describe "cancel_job/1" do
    test "cancels a pending job" do
      job = create_job(%{status: "pending"})

      assert {:ok, cancelled} = Ingestion.cancel_job(job.id)
      assert cancelled.status == "failed"
      assert cancelled.error == "cancelled"
    end

    test "returns error if job is not pending" do
      job = create_job(%{status: "processing"})
      assert {:error, :not_pending} = Ingestion.cancel_job(job.id)
    end

    test "returns error if job not found" do
      assert {:error, :not_found} = Ingestion.cancel_job(Ecto.UUID.generate())
    end
  end
end
