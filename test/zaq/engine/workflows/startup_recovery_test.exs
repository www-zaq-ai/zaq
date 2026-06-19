defmodule Zaq.Engine.Workflows.StartupRecoveryTest do
  use Zaq.DataCase, async: false
  use Oban.Testing, repo: Zaq.Repo

  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.RunRecoveryWorker
  alias Zaq.Engine.Workflows.StartupRecovery
  alias Zaq.Test.Stubs

  require Logger

  setup do
    Stubs.stub_node_router()
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

  describe "run/1 (Oban testing :inline — jobs perform on enqueue)" do
    test "recovers all stale runs on startup" do
      w = create_workflow()
      running = create_run(w, "running")
      pending = create_run(w, "pending")

      StartupRecovery.run([])

      assert Workflows.get_run!(running.id).status == "interrupted"
      assert Workflows.get_run!(pending.id).status == "interrupted"
    end

    test "does not touch terminal runs" do
      w = create_workflow()
      completed = create_run(w, "completed")
      failed = create_run(w, "failed")

      StartupRecovery.run([])

      assert Workflows.get_run!(completed.id).status == "completed"
      assert Workflows.get_run!(failed.id).status == "failed"
    end

    test "exits cleanly when no stale runs exist" do
      assert :ok == StartupRecovery.run([])
    end

    test "recovers every stale run independently" do
      w = create_workflow()
      run1 = create_run(w, "running")
      run2 = create_run(w, "running")

      StartupRecovery.run([])

      assert Workflows.get_run!(run1.id).status == "interrupted"
      assert Workflows.get_run!(run2.id).status == "interrupted"
    end

    test "logs at info level when stale runs exist" do
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: :warning) end)

      w = create_workflow()
      create_run(w, "running")

      assert :ok == StartupRecovery.run([])
    end
  end

  describe "run/1 enqueues jobs (manual mode)" do
    test "enqueues one RunRecoveryWorker job per stale run without performing inline" do
      w = create_workflow()
      running = create_run(w, "running")
      pending = create_run(w, "pending")

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert :ok == StartupRecovery.run([])

        run_ids =
          [worker: RunRecoveryWorker]
          |> all_enqueued()
          |> Enum.map(& &1.args["run_id"])

        assert running.id in run_ids
        assert pending.id in run_ids
      end)

      # Nothing performed inline under manual mode
      assert Workflows.get_run!(running.id).status == "running"
    end
  end
end
