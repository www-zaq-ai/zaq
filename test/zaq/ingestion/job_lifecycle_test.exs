defmodule Zaq.Ingestion.JobLifecycleTest do
  use Zaq.DataCase, async: false

  alias Zaq.Ingestion.{IngestJob, JobLifecycle}
  alias Zaq.Repo

  @topic "ingestion:jobs"

  setup do
    Phoenix.PubSub.subscribe(Zaq.PubSub, @topic)
    :ok
  end

  describe "transition/2 and transition!/2" do
    test "updates job and broadcasts on transition/2" do
      job = create_job(%{status: "pending"})
      job_id = job.id

      assert {:ok, updated} = JobLifecycle.transition(job, %{status: "processing"})
      assert updated.status == "processing"
      assert_receive {:job_updated, %{id: ^job_id, status: "processing"}}
    end

    test "returns changeset error for invalid attrs" do
      job = create_job()

      assert {:error, changeset} = JobLifecycle.transition(job, %{status: "nope"})
      assert %{status: ["is invalid"]} = errors_on(changeset)
    end

    test "bang variant updates and broadcasts" do
      job = create_job(%{status: "pending"})
      job_id = job.id

      updated = JobLifecycle.transition!(job, %{status: "processing"})

      assert updated.status == "processing"
      assert_receive {:job_updated, %{id: ^job_id, status: "processing"}}
    end
  end

  describe "status helper transitions" do
    test "mark_processing!/1 sets status and started_at" do
      job = create_job(%{status: "pending", started_at: nil})
      job_id = job.id

      updated = JobLifecycle.mark_processing!(job)

      assert updated.status == "processing"
      assert %DateTime{} = updated.started_at
      assert_receive {:job_updated, %{id: ^job_id, status: "processing"}}
    end

    test "mark_completed!/2 sets status, completed_at and merged attrs" do
      job = create_job(%{status: "processing", completed_at: nil})
      job_id = job.id

      updated = JobLifecycle.mark_completed!(job, %{chunks_count: 3})

      assert updated.status == "completed"
      assert updated.chunks_count == 3
      assert %DateTime{} = updated.completed_at
      assert_receive {:job_updated, %{id: ^job_id, status: "completed", chunks_count: 3}}
    end

    test "mark_failed/3 without completed flag keeps completed_at nil" do
      job = create_job(%{status: "processing", completed_at: nil})
      job_id = job.id

      assert {:ok, updated} = JobLifecycle.mark_failed(job, "boom")

      assert updated.status == "failed"
      assert updated.error == "boom"
      assert is_nil(updated.completed_at)
      assert_receive {:job_updated, %{id: ^job_id, status: "failed", error: "boom"}}
    end

    test "mark_failed/3 with completed flag sets completed_at" do
      job = create_job(%{status: "processing", completed_at: nil})
      job_id = job.id

      assert {:ok, updated} = JobLifecycle.mark_failed(job, "boom", completed: true)

      assert updated.status == "failed"
      assert updated.error == "boom"
      assert %DateTime{} = updated.completed_at
      assert_receive {:job_updated, %{id: ^job_id, status: "failed", error: "boom"}}
    end

    test "mark_failed!/3 sets completed_at when requested" do
      job = create_job(%{status: "processing", completed_at: nil})
      job_id = job.id

      updated = JobLifecycle.mark_failed!(job, "fatal", completed: true)

      assert updated.status == "failed"
      assert updated.error == "fatal"
      assert %DateTime{} = updated.completed_at
      assert_receive {:job_updated, %{id: ^job_id, status: "failed", error: "fatal"}}
    end

    test "mark_pending_retry!/2 returns pending with error message" do
      job = create_job(%{status: "failed"})
      job_id = job.id

      updated = JobLifecycle.mark_pending_retry!(job, "Attempt 2 failed")

      assert updated.status == "pending"
      assert updated.error == "Attempt 2 failed"
      assert_receive {:job_updated, %{id: ^job_id, status: "pending", error: "Attempt 2 failed"}}
    end
  end

  defp create_job(attrs \\ %{}) do
    %IngestJob{}
    |> IngestJob.changeset(
      Map.merge(%{file_path: "docs/test.md", status: "pending", mode: "async"}, attrs)
    )
    |> Repo.insert!()
  end
end
