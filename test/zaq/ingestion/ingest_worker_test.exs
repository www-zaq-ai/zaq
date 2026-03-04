defmodule Zaq.Ingestion.IngestWorkerTest do
  use Zaq.DataCase, async: true

  import Mox

  alias Zaq.Ingestion.{IngestJob, IngestWorker}
  alias Zaq.Repo

  setup :verify_on_exit!

  defp create_job(attrs \\ %{}) do
    %IngestJob{}
    |> IngestJob.changeset(
      Map.merge(%{file_path: "docs/test.md", status: "pending", mode: "async"}, attrs)
    )
    |> Repo.insert!()
  end

  describe "perform/1" do
    test "sets status to completed on success" do
      job = create_job()

      expect(Zaq.DocumentProcessorMock, :process_single_file, fn "docs/test.md" ->
        {:ok, %{chunks_count: 5, document_id: nil}}
      end)

      assert :ok = IngestWorker.perform(%Oban.Job{args: %{"job_id" => job.id}})

      updated = Repo.get!(IngestJob, job.id)
      assert updated.status == "completed"
      assert updated.chunks_count == 5
      assert updated.started_at != nil
      assert updated.completed_at != nil
    end

    test "sets status to failed on error" do
      job = create_job()

      expect(Zaq.DocumentProcessorMock, :process_single_file, fn "docs/test.md" ->
        {:error, :parse_error}
      end)

      assert {:error, :parse_error} =
               IngestWorker.perform(%Oban.Job{args: %{"job_id" => job.id}})

      updated = Repo.get!(IngestJob, job.id)
      assert updated.status == "failed"
      assert updated.error == "parse_error"
      assert updated.completed_at != nil
    end
  end
end
