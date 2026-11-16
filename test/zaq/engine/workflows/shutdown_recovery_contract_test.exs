defmodule Zaq.Engine.Workflows.ShutdownRecoveryContractTest do
  # Public contract for what happens to runs a shutdown left behind: they are
  # marked `interrupted`, never resumed in-process, and the operator (or the
  # BO list page) picks them up again through `retry_run/2` and
  # `list_workflows_with_details/0`.
  use Zaq.DataCase, async: true

  import Ecto.Query

  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.WorkflowRun
  alias Zaq.Repo

  @node %{
    name: "fetch",
    type: "action",
    module: "Zaq.Engine.Workflows.Test.InboxWithResults",
    params: %{},
    index: 0
  }

  setup do
    stub(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{} = event -> event end)
    :ok
  end

  defp workflow(name) do
    {:ok, wf} =
      Workflows.create_workflow(%{
        name: "#{name} #{System.unique_integer([:positive])}",
        status: "active",
        nodes: [@node]
      })

    wf
  end

  defp run(wf, status, trace_id \\ Ecto.UUID.generate()) do
    {:ok, run} =
      Workflows.create_run(wf, %{
        "request" => nil,
        "assigns" => %{"trigger_type" => "manual"},
        "trace_id" => trace_id
      })

    {:ok, run} = Workflows.update_run(run, %{status: status})
    run
  end

  describe "retry_run/2 after a shutdown" do
    test "creates a fresh pending run from an interrupted, failed or cancelled run" do
      wf = workflow("Retry")

      for status <- ["interrupted", "failed", "cancelled"] do
        trace_id = Ecto.UUID.generate()
        original = run(wf, status, trace_id)

        assert {:ok, retried} = Workflows.retry_run(original)

        assert retried.id != original.id
        assert retried.workflow_id == wf.id
        assert retried.status == "pending"
        assert retried.source_event.trace_id == trace_id

        # The original keeps its terminal status; only the retry is new.
        assert Repo.get!(WorkflowRun, original.id).status == status
        assert Repo.get!(WorkflowRun, retried.id).status == "pending"
      end

      assert Workflows.count_runs(wf.id) == 6
    end

    test "refuses runs that are still live or already completed" do
      wf = workflow("NoRetry")

      for status <- ["pending", "running", "completed"] do
        original = run(wf, status)
        assert {:error, :not_retryable} = Workflows.retry_run(original)
      end

      assert Workflows.count_runs(wf.id) == 3
    end
  end

  describe "list_workflows_with_details/0" do
    test "reports per-workflow run counts, triggers and latest run in name order" do
      busy = workflow("A busy")
      idle = workflow("B idle")
      other = workflow("C other")

      {:ok, trigger} =
        Workflows.create_trigger(%{event_name: "details_#{System.unique_integer([:positive])}"})

      Workflows.assign_workflow_to_trigger(trigger, busy)

      older = run(busy, "interrupted")
      latest = run(busy, "pending")
      foreign = run(other, "completed")

      # inserted_at has second precision; pin the ordering deterministically.
      for {r, secs} <- [{older, -60}, {latest, 0}] do
        stamp = DateTime.add(DateTime.utc_now(:second), secs)
        Repo.update_all(from(x in WorkflowRun, where: x.id == ^r.id), set: [inserted_at: stamp])
      end

      details =
        Workflows.list_workflows_with_details()
        |> Map.new(fn {wf, count, triggers, last} -> {wf.id, {count, triggers, last}} end)

      assert {2, [%{id: trigger_id}], %WorkflowRun{id: latest_id}} = details[busy.id]
      assert trigger_id == trigger.id
      assert latest_id == latest.id

      assert {0, [], nil} = details[idle.id]

      assert {1, [], %WorkflowRun{id: foreign_id}} = details[other.id]
      assert foreign_id == foreign.id

      names =
        Workflows.list_workflows_with_details()
        |> Enum.map(fn {wf, _, _, _} -> wf.name end)
        |> Enum.filter(&String.starts_with?(&1, ["A busy", "B idle", "C other"]))

      assert names == Enum.sort(names)
    end
  end
end
