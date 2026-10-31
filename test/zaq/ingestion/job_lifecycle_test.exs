defmodule Zaq.Ingestion.JobLifecycleTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties

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

  describe "broadcast_progress/2" do
    test "broadcasts a transient job_progress event on the jobs topic" do
      payload = %{
        "stage" => "image_to_text",
        "current" => 2,
        "total" => 5,
        "status" => "processing"
      }

      assert :ok = JobLifecycle.broadcast_progress("job-123", payload)
      assert_receive {:job_progress, "job-123", ^payload}
    end

    test "does not persist anything to the database" do
      job = create_job(%{status: "processing"})

      :ok = JobLifecycle.broadcast_progress(job.id, %{"current" => 1, "total" => 1})

      # The job row is untouched by a progress broadcast.
      assert Repo.get!(IngestJob, job.id).status == "processing"
      assert_receive {:job_progress, _, %{"current" => 1}}
    end
  end

  describe "durable preparation progress" do
    test "clears progress saved after the worker loaded its job struct" do
      for attrs <- [%{status: "failed"}, %{status: "pending"}, %{total_chunks: 6}],
          transition <- [:transition, :transition!] do
        stale_job = create_job(%{status: "processing"})
        assert is_nil(stale_job.preparation_progress)

        assert :ok =
                 JobLifecycle.report_preparation_progress(stale_job.id, %{"current" => 6})

        apply(JobLifecycle, transition, [stale_job, attrs])

        assert is_nil(Repo.get!(IngestJob, stale_job.id).preparation_progress)
      end
    end

    test "saves the latest snapshot before broadcasting progress" do
      job = create_job(%{status: "processing"})
      payload = %{"stage" => "image_to_text", "current" => 6, "total" => 6}

      assert :ok = JobLifecycle.report_preparation_progress(job.id, payload)
      assert_receive {:job_progress, id, ^payload}
      assert id == job.id

      snapshot = Repo.get!(IngestJob, job.id).preparation_progress
      assert snapshot["payload"] == payload
      assert {:ok, _, 0} = DateTime.from_iso8601(snapshot["reported_at"])

      next_payload = Map.put(payload, "current", 7)
      assert :ok = JobLifecycle.report_preparation_progress(job.id, next_payload)
      assert Repo.get!(IngestJob, job.id).preparation_progress["payload"] == next_payload
    end

    property "late progress is ignored outside active preparation" do
      check all(
              status <- member_of(IngestJob.statuses()),
              chunks <- integer(0..2),
              finished? <- boolean(),
              max_runs: 20
            ) do
        job =
          create_job(%{
            status: status,
            total_chunks: chunks,
            completed_at: if(finished?, do: DateTime.utc_now())
          })

        assert :ok = JobLifecycle.report_preparation_progress(job.id, %{"current" => 1})
        snapshot = Repo.get!(IngestJob, job.id).preparation_progress

        if status == "processing" and chunks == 0 and not finished? do
          assert snapshot["payload"] == %{"current" => 1}
        else
          assert is_nil(snapshot)
          job_id = job.id
          refute_receive {:job_progress, ^job_id, _}
        end
      end
    end

    test "a new attempt clears the previous attempt's snapshot" do
      job = create_job(%{status: "processing"})
      assert :ok = JobLifecycle.report_preparation_progress(job.id, %{"current" => 6})

      restarted = JobLifecycle.mark_processing!(Repo.get!(IngestJob, job.id))

      assert is_nil(restarted.preparation_progress)
      assert is_nil(Repo.get!(IngestJob, job.id).preparation_progress)
    end

    test "both transition variants discard preparation progress when preparation ends" do
      for attrs <- [
            %{status: "pending"},
            %{status: "failed"},
            %{status: "completed"},
            %{total_chunks: 6}
          ],
          transition <- [:transition, :transition!] do
        job = create_job(%{status: "processing"})
        assert :ok = JobLifecycle.report_preparation_progress(job.id, %{"current" => 6})

        apply(JobLifecycle, transition, [Repo.get!(IngestJob, job.id), attrs])

        assert is_nil(Repo.get!(IngestJob, job.id).preparation_progress)
      end
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
