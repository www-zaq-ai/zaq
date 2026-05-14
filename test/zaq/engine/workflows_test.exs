defmodule Zaq.Engine.WorkflowsTest do
  use Zaq.DataCase, async: true

  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.Trigger

  @valid_node %{
    name: "fetch",
    type: "action",
    module: "Zaq.Agent.Tools.Email.FetchEmails",
    params: %{},
    index: 0
  }

  defp create_workflow(attrs \\ %{}) do
    {:ok, w} =
      Workflows.create_workflow(
        Map.merge(%{name: "W", status: "draft", nodes: [@valid_node], edges: []}, attrs)
      )

    w
  end

  defp create_trigger(attrs \\ %{}) do
    {:ok, t} = Workflows.create_trigger(Map.merge(%{type: "manual"}, attrs))
    t
  end

  # --- list_triggers/1 ---

  describe "list_triggers/1" do
    test "returns all triggers regardless of workflow" do
      t1 = create_trigger(%{type: "manual"})
      t2 = create_trigger(%{type: "webhook"})
      ids = Workflows.list_triggers() |> Enum.map(& &1.id)
      assert t1.id in ids
      assert t2.id in ids
    end

    test "returns empty list when no triggers" do
      assert [] = Workflows.list_triggers()
    end
  end

  # --- list_triggers_for_workflow/2 ---

  describe "list_triggers_for_workflow/2" do
    test "returns only triggers assigned to the workflow" do
      w1 = create_workflow()
      w2 = create_workflow(%{name: "W2"})
      t1 = create_trigger()
      t2 = create_trigger()
      Workflows.assign_workflow_to_trigger(t1, w1)
      Workflows.assign_workflow_to_trigger(t2, w2)

      result = Workflows.list_triggers_for_workflow(w1.id)
      ids = Enum.map(result, & &1.id)
      assert t1.id in ids
      refute t2.id in ids
    end

    test "returns triggers ordered by position" do
      w = create_workflow()
      t1 = create_trigger(%{type: "manual"})
      t2 = create_trigger(%{type: "webhook"})
      Workflows.assign_workflow_to_trigger(t1, w, position: 1)
      Workflows.assign_workflow_to_trigger(t2, w, position: 0)

      [first, second] = Workflows.list_triggers_for_workflow(w.id)
      assert first.id == t2.id
      assert second.id == t1.id
    end
  end

  # --- create_trigger/2 ---

  describe "create_trigger/2" do
    test "creates a trigger with no workflows" do
      assert {:ok, %Trigger{} = t} = Workflows.create_trigger(%{type: "manual"})
      assert t.type == "manual"
      assert t.execution_mode == :parallel
      assert t.on_failure == :continue
    end

    test "creates a scheduler trigger with cron config" do
      assert {:ok, %Trigger{}} =
               Workflows.create_trigger(%{type: "scheduler", config: %{"cron" => "0 * * * *"}})
    end

    test "rejects scheduler without cron" do
      assert {:error, cs} = Workflows.create_trigger(%{type: "scheduler", config: %{}})
      assert "missing required key 'cron' for scheduler trigger" in errors_on(cs).config
    end

    test "creates trigger with serial execution_mode and on_failure :stop" do
      assert {:ok, t} =
               Workflows.create_trigger(%{
                 type: "manual",
                 execution_mode: "serial",
                 on_failure: "stop"
               })

      assert t.execution_mode == :serial
      assert t.on_failure == :stop
    end
  end

  # --- assign_workflow_to_trigger/3 ---

  describe "assign_workflow_to_trigger/3" do
    test "inserts join row" do
      t = create_trigger()
      w = create_workflow()
      assert {:ok, _} = Workflows.assign_workflow_to_trigger(t, w)

      [assigned] = Workflows.list_triggers_for_workflow(w.id)
      assert assigned.id == t.id
    end

    test "is idempotent — second call does not error" do
      t = create_trigger()
      w = create_workflow()
      assert {:ok, _} = Workflows.assign_workflow_to_trigger(t, w)
      assert {:ok, _} = Workflows.assign_workflow_to_trigger(t, w)
    end

    test "stores position" do
      t = create_trigger()
      w = create_workflow()
      {:ok, row} = Workflows.assign_workflow_to_trigger(t, w, position: 5)
      assert row.position == 5
    end
  end

  # --- remove_workflow_from_trigger/3 ---

  describe "remove_workflow_from_trigger/3" do
    test "removes the join row" do
      t = create_trigger()
      w = create_workflow()
      Workflows.assign_workflow_to_trigger(t, w)
      assert {:ok, _} = Workflows.remove_workflow_from_trigger(t, w)
      assert [] = Workflows.list_triggers_for_workflow(w.id)
    end

    test "returns error when assignment does not exist" do
      t = create_trigger()
      w = create_workflow()
      assert {:error, :not_found} = Workflows.remove_workflow_from_trigger(t, w)
    end
  end

  # --- chain_trigger/3 ---

  describe "chain_trigger/3" do
    test "inserts a downstream chain" do
      t1 = create_trigger()
      t2 = create_trigger()
      assert {:ok, _} = Workflows.chain_trigger(t1, t2)
    end

    test "is idempotent" do
      t1 = create_trigger()
      t2 = create_trigger()
      assert {:ok, _} = Workflows.chain_trigger(t1, t2)
      assert {:ok, _} = Workflows.chain_trigger(t1, t2)
    end

    test "rejects direct self-cycle" do
      t = create_trigger()
      assert {:error, :cycle_detected} = Workflows.chain_trigger(t, t)
    end

    test "rejects indirect cycle A→B, B→A" do
      t1 = create_trigger()
      t2 = create_trigger()
      {:ok, _} = Workflows.chain_trigger(t1, t2)
      assert {:error, :cycle_detected} = Workflows.chain_trigger(t2, t1)
    end

    test "rejects multi-hop cycle A→B→C, C→A" do
      t1 = create_trigger()
      t2 = create_trigger()
      t3 = create_trigger()
      {:ok, _} = Workflows.chain_trigger(t1, t2)
      {:ok, _} = Workflows.chain_trigger(t2, t3)
      assert {:error, :cycle_detected} = Workflows.chain_trigger(t3, t1)
    end

    test "allows diamond shape A→B, A→C, B→D, C→D (no cycle)" do
      [a, b, c, d] = for _ <- 1..4, do: create_trigger()
      assert {:ok, _} = Workflows.chain_trigger(a, b)
      assert {:ok, _} = Workflows.chain_trigger(a, c)
      assert {:ok, _} = Workflows.chain_trigger(b, d)
      assert {:ok, _} = Workflows.chain_trigger(c, d)
    end
  end

  # --- unchain_trigger/3 ---

  describe "unchain_trigger/3" do
    test "removes the chain row" do
      t1 = create_trigger()
      t2 = create_trigger()
      Workflows.chain_trigger(t1, t2)
      assert {:ok, _} = Workflows.unchain_trigger(t1, t2)
    end

    test "returns error when chain does not exist" do
      t1 = create_trigger()
      t2 = create_trigger()
      assert {:error, :not_found} = Workflows.unchain_trigger(t1, t2)
    end
  end

  # --- delete_trigger/2 ---

  describe "delete_trigger/2" do
    test "deletes trigger and cascades to trigger_workflows" do
      t = create_trigger()
      w = create_workflow()
      Workflows.assign_workflow_to_trigger(t, w)
      assert {:ok, _} = Workflows.delete_trigger(t)
      assert [] = Workflows.list_triggers_for_workflow(w.id)
    end

    test "deletes trigger and cascades to trigger_chains" do
      t1 = create_trigger()
      t2 = create_trigger()
      Workflows.chain_trigger(t1, t2)
      assert {:ok, _} = Workflows.delete_trigger(t1)
      # t2 still exists but t1 is gone
      remaining_ids = Workflows.list_triggers() |> Enum.map(& &1.id)
      refute t1.id in remaining_ids
      assert t2.id in remaining_ids
    end
  end

  # --- run_workflow_manually/3 ---

  describe "run_workflow_manually/3" do
    test "creates and completes a run without a trigger record" do
      w = create_workflow(%{name: "ManualRun", status: "active"})
      assert {:ok, run} = Workflows.run_workflow_manually(w.id, %{})
      assert run.workflow_id == w.id
      assert run.status in ["completed", "failed"]
      assert run.source_event.assigns.trigger_type == :manual
    end

    test "returns error for unknown workflow id" do
      assert {:error, _} = Workflows.run_workflow_manually(Ecto.UUID.generate(), %{})
    end
  end
end
