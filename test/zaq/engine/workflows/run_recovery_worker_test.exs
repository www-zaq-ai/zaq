defmodule Zaq.Engine.Workflows.RunRecoveryWorkerTest do
  use Zaq.DataCase, async: false
  use Oban.Testing, repo: Zaq.Repo

  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.RunRecoveryWorker

  setup do
    stub(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{} = event -> event end)
    :ok
  end

  @valid_node %{
    name: "fetch",
    type: "action",
    module: "Zaq.Engine.Workflows.Test.InboxWithResults",
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
    test "interrupts a stuck run with the honest unplanned_termination reason" do
      run = create_run(create_workflow(), "running")

      {:ok, step_run} =
        Workflows.create_step_run(run, %{step_name: "fetch", step_index: 0, status: "running"})

      assert :ok = perform_job(RunRecoveryWorker, %{run_id: run.id})

      interrupted = Workflows.get_run!(run.id)
      assert interrupted.status == "interrupted"

      # This worker only ever runs on a run that `prep_stop/1` never got to —
      # i.e. a genuine unplanned death, not a graceful restart — and that must
      # be reflected honestly, distinct from the "graceful_shutdown" label
      # `prep_stop/1` uses for the common, deliberate-restart case.
      recovered_step =
        run.id |> Workflows.list_step_runs() |> Enum.find(&(&1.id == step_run.id))

      assert recovered_step.status == "failed"
      assert recovered_step.errors["reason"] == "unplanned_termination"
      refute recovered_step.errors["reason"] == "graceful_shutdown"
    end

    test "is a no-op for a run that no longer exists" do
      assert :ok = perform_job(RunRecoveryWorker, %{run_id: Ecto.UUID.generate()})
    end

    test "returns {:error, reason} when interrupt_run fails (job will retry)" do
      run = create_run(create_workflow(), "running")

      defmodule FailingWorkflows do
        alias Zaq.Engine.Workflows
        def list_stale_runs, do: Workflows.list_stale_runs()
        def interrupt_run(_run, _opts), do: {:error, :forced_test_failure}
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

    test "does not count stale runs whose recovery job cannot be inserted" do
      defmodule OneStaleRunWorkflows do
        def list_stale_runs, do: [%{id: Ecto.UUID.generate()}]
      end

      Application.put_env(:zaq, :startup_recovery_workflows_mod, OneStaleRunWorkflows)
      on_exit(fn -> Application.delete_env(:zaq, :startup_recovery_workflows_mod) end)

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert 0 =
                 RunRecoveryWorker.enqueue_all(
                   insert_fun: fn %Ecto.Changeset{} -> {:error, :down} end
                 )

        assert all_enqueued(worker: RunRecoveryWorker) == []
      end)
    end
  end
end
