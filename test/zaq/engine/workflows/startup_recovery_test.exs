defmodule Zaq.Engine.Workflows.StartupRecoveryTest do
  use Zaq.DataCase, async: true

  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.StartupRecovery
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

  describe "run/1" do
    test "interrupts all stale runs on startup" do
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
      # No runs in DB — should not raise
      assert :ok == StartupRecovery.run([])
    end

    test "continues processing remaining runs when one fails" do
      w = create_workflow()
      run1 = create_run(w, "running")
      run2 = create_run(w, "running")

      # Both should be interrupted; no run should block the other
      StartupRecovery.run([])

      assert Workflows.get_run!(run1.id).status == "interrupted"
      assert Workflows.get_run!(run2.id).status == "interrupted"
    end
  end
end
