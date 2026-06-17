defmodule Zaq.Engine.Workflows.RunRecoveryWorkerTest do
  use Zaq.DataCase, async: false
  use Oban.Testing, repo: Zaq.Repo

  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.RunRecoveryWorker
  alias Zaq.Test.Stubs

  setup do
    Stubs.stub_node_router()
    :ok
  end

  @valid_node %{
    name: "fetch",
    type: "action",
    module: "Zaq.Agent.Tools.Email.FetchEmails",
    params: %{},
    index: 0
  }

  defp create_workflow do
    {:ok, w} =
      Workflows.create_workflow(%{name: "W", status: "draft", nodes: [@valid_node], edges: []})

    w
  end

  defp create_run(workflow, status) do
    source_event = %Zaq.Event{
      request: nil,
      next_hop: nil,
      trace_id: Ecto.UUID.generate(),
      assigns: %{trigger_type: :manual, input: %{}}
    }

    {:ok, run} = Workflows.create_run(workflow, source_event)

    if status != "pending" do
      {:ok, updated} = Workflows.update_run(run, %{status: status})
      updated
    else
      run
    end
  end

  describe "perform/1" do
    test "interrupts a stuck run" do
      run = create_run(create_workflow(), "running")

      assert :ok = perform_job(RunRecoveryWorker, %{run_id: run.id})
      assert Workflows.get_run!(run.id).status == "interrupted"
    end

    test "is a no-op for a run that no longer exists" do
      assert :ok = perform_job(RunRecoveryWorker, %{run_id: Ecto.UUID.generate()})
    end

    test "returns {:error, reason} when interrupt_run fails (job will retry)" do
      run = create_run(create_workflow(), "running")

      defmodule FailingWorkflows do
        alias Zaq.Engine.Workflows
        def list_stale_runs, do: Workflows.list_stale_runs()
        def interrupt_run(_run), do: {:error, :forced_test_failure}
      end

      Application.put_env(:zaq, :startup_recovery_workflows_mod, FailingWorkflows)
      on_exit(fn -> Application.delete_env(:zaq, :startup_recovery_workflows_mod) end)

      assert {:error, :forced_test_failure} = perform_job(RunRecoveryWorker, %{run_id: run.id})
      # Run is left untouched so the retry can recover it
      assert Workflows.get_run!(run.id).status == "running"
    end
  end

  describe "enqueue_all/1" do
    test "enqueues one unique job per stale run" do
      w = create_workflow()
      running = create_run(w, "running")
      pending = create_run(w, "pending")
      _completed = create_run(w, "completed")

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert 2 = RunRecoveryWorker.enqueue_all()

        enqueued = all_enqueued(worker: RunRecoveryWorker)
        run_ids = Enum.map(enqueued, & &1.args["run_id"])

        assert length(enqueued) == 2
        assert running.id in run_ids
        assert pending.id in run_ids
      end)
    end

    test "a duplicate enqueue is deduped by the unique constraint" do
      run = create_run(create_workflow(), "running")

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert 1 = RunRecoveryWorker.enqueue_all()
        # Second sweep finds the same stale run but the job is still pending,
        # so the unique constraint makes it a no-op.
        assert 0 = RunRecoveryWorker.enqueue_all()

        assert [job] = all_enqueued(worker: RunRecoveryWorker)
        assert job.args["run_id"] == run.id
      end)
    end

    test "returns 0 when there are no stale runs" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        assert 0 = RunRecoveryWorker.enqueue_all()
        assert all_enqueued(worker: RunRecoveryWorker) == []
      end)
    end
  end
end
