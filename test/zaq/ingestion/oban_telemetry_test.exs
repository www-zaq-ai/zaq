defmodule Zaq.Ingestion.ObanTelemetryTest do
  use Zaq.DataCase, async: false

  alias Zaq.Ingestion.{IngestJob, ObanTelemetry}
  alias Zaq.Repo

  defp create_job(attrs) do
    %IngestJob{}
    |> IngestJob.changeset(
      Map.merge(%{file_path: "docs/test.md", status: "pending", mode: "async"}, attrs)
    )
    |> Repo.insert!()
  end

  describe "handle_event/4" do
    test "marks matching ingestion jobs as failed and broadcasts" do
      job = create_job(%{status: "processing"})
      Zaq.Ingestion.subscribe()

      meta = %{
        state: :discard,
        job: %{worker: "Zaq.Ingestion.IngestWorker", args: %{"job_id" => job.id}}
      }

      assert :ok == ObanTelemetry.handle_event([:oban, :job, :exception], %{}, meta, nil)
      job_id = job.id

      updated = Repo.get!(IngestJob, job.id)
      assert updated.status == "failed"
      assert updated.error == "Max retries exhausted"
      assert updated.completed_at != nil

      assert_receive {:job_updated,
                      %{id: ^job_id, status: "failed", error: "Max retries exhausted"}}
    end

    test "ignores non-ingestion workers" do
      job = create_job(%{status: "processing"})

      meta = %{
        state: :discard,
        job: %{worker: "Other.Worker", args: %{"job_id" => job.id}}
      }

      assert :ok == ObanTelemetry.handle_event([:oban, :job, :exception], %{}, meta, nil)

      updated = Repo.get!(IngestJob, job.id)
      assert updated.status == "processing"
      assert updated.error == nil
    end

    test "ignores jobs that are already failed" do
      job = create_job(%{status: "failed", error: "existing"})

      meta = %{
        state: :discard,
        job: %{worker: "Zaq.Ingestion.IngestWorker", args: %{"job_id" => job.id}}
      }

      assert :ok == ObanTelemetry.handle_event([:oban, :job, :exception], %{}, meta, nil)

      updated = Repo.get!(IngestJob, job.id)
      assert updated.status == "failed"
      assert updated.error == "existing"
    end
  end
end
