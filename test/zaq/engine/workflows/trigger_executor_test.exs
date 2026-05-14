defmodule Zaq.Engine.Workflows.TriggerExecutorTest do
  use Zaq.DataCase, async: true

  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.TriggerExecutor

  @valid_node %{
    name: "fetch",
    type: "action",
    module: "Zaq.Agent.Tools.Email.FetchEmails",
    params: %{},
    index: 0
  }

  defp create_workflow(name \\ "W") do
    {:ok, w} =
      Workflows.create_workflow(%{
        name: name,
        status: "active",
        nodes: [@valid_node],
        edges: []
      })

    w
  end

  defp create_trigger(attrs \\ %{}) do
    {:ok, t} = Workflows.create_trigger(Map.merge(%{type: "manual"}, attrs))
    t
  end

  # --- parallel execution ---

  describe "execute/3 — parallel mode" do
    test "dispatches all assigned workflows" do
      w1 = create_workflow("W1")
      w2 = create_workflow("W2")
      t = create_trigger(%{execution_mode: "parallel"})
      Workflows.assign_workflow_to_trigger(t, w1)
      Workflows.assign_workflow_to_trigger(t, w2)

      {:ok, results} = TriggerExecutor.execute(t, %{})
      workflow_ids = Enum.map(results, fn {wid, _} -> wid end)
      assert w1.id in workflow_ids
      assert w2.id in workflow_ids
    end

    test "all workflows run even if one fails" do
      w1 = create_workflow("W1")
      # W2 with an invalid module forces a failed run
      {:ok, w2} =
        Workflows.create_workflow(%{
          name: "W2",
          status: "active",
          nodes: [%{@valid_node | module: "Zaq.Engine.Workflows.NonExistent"}],
          edges: []
        })

      t = create_trigger(%{execution_mode: "parallel"})
      Workflows.assign_workflow_to_trigger(t, w1)
      Workflows.assign_workflow_to_trigger(t, w2)

      {:ok, results} = TriggerExecutor.execute(t, %{})
      assert length(results) == 2
    end

    test "respects max_concurrency" do
      workflows = for i <- 1..4, do: create_workflow("W#{i}")
      t = create_trigger(%{execution_mode: "parallel", max_concurrency: 2})
      for w <- workflows, do: Workflows.assign_workflow_to_trigger(t, w)

      {:ok, results} = TriggerExecutor.execute(t, %{})
      assert length(results) == 4
    end

    test "returns list of {workflow_id, {:ok | :error, run_or_reason}} tuples" do
      w = create_workflow()
      t = create_trigger(%{execution_mode: "parallel"})
      Workflows.assign_workflow_to_trigger(t, w)

      {:ok, [{wid, {status, _run}}]} = TriggerExecutor.execute(t, %{})
      assert wid == w.id
      assert status in [:ok, :error]
    end

    test "returns ok with empty results when no workflows assigned" do
      t = create_trigger(%{execution_mode: "parallel"})
      assert {:ok, []} = TriggerExecutor.execute(t, %{})
    end
  end

  # --- serial execution ---

  describe "execute/3 — serial mode, on_failure :stop" do
    test "runs all when all succeed" do
      w1 = create_workflow("W1")
      w2 = create_workflow("W2")
      t = create_trigger(%{execution_mode: "serial", on_failure: "stop"})
      Workflows.assign_workflow_to_trigger(t, w1, position: 0)
      Workflows.assign_workflow_to_trigger(t, w2, position: 1)

      {:ok, results} = TriggerExecutor.execute(t, %{})
      assert length(results) == 2
    end

    test "stops after first failure" do
      {:ok, w1} =
        Workflows.create_workflow(%{
          name: "W1",
          status: "active",
          nodes: [%{@valid_node | module: "Zaq.Engine.Workflows.NonExistent"}],
          edges: []
        })

      w2 = create_workflow("W2")
      t = create_trigger(%{execution_mode: "serial", on_failure: "stop"})
      Workflows.assign_workflow_to_trigger(t, w1, position: 0)
      Workflows.assign_workflow_to_trigger(t, w2, position: 1)

      {:ok, results} = TriggerExecutor.execute(t, %{})
      # Only w1 attempted; w2 skipped
      assert length(results) == 1
      [{wid, _}] = results
      assert wid == w1.id
    end
  end

  describe "execute/3 — serial mode, on_failure :continue" do
    test "runs all even if one fails" do
      {:ok, w1} =
        Workflows.create_workflow(%{
          name: "W1",
          status: "active",
          nodes: [%{@valid_node | module: "Zaq.Engine.Workflows.NonExistent"}],
          edges: []
        })

      w2 = create_workflow("W2")
      t = create_trigger(%{execution_mode: "serial", on_failure: "continue"})
      Workflows.assign_workflow_to_trigger(t, w1, position: 0)
      Workflows.assign_workflow_to_trigger(t, w2, position: 1)

      {:ok, results} = TriggerExecutor.execute(t, %{})
      assert length(results) == 2
    end

    test "workflows run in position order" do
      w1 = create_workflow("W1")
      w2 = create_workflow("W2")
      w3 = create_workflow("W3")
      t = create_trigger(%{execution_mode: "serial", on_failure: "continue"})
      # Insert out of order
      Workflows.assign_workflow_to_trigger(t, w3, position: 2)
      Workflows.assign_workflow_to_trigger(t, w1, position: 0)
      Workflows.assign_workflow_to_trigger(t, w2, position: 1)

      {:ok, results} = TriggerExecutor.execute(t, %{})
      executed_ids = Enum.map(results, fn {wid, _} -> wid end)
      assert executed_ids == [w1.id, w2.id, w3.id]
    end
  end

  # --- downstream trigger chaining ---

  describe "execute/3 — downstream trigger chaining" do
    test "fires downstream triggers after own workflows complete" do
      w1 = create_workflow("W1")
      w2 = create_workflow("W2")

      t1 = create_trigger()
      t2 = create_trigger()
      Workflows.assign_workflow_to_trigger(t1, w1)
      Workflows.assign_workflow_to_trigger(t2, w2)
      Workflows.chain_trigger(t1, t2)

      # Reload t1 with associations
      t1 = Workflows.get_trigger!(t1.id)

      {:ok, results} = TriggerExecutor.execute(t1, %{})
      # Results include runs from t1's own workflows AND t2's
      all_workflow_ids = Enum.map(results, fn {wid, _} -> wid end)
      assert w1.id in all_workflow_ids
      assert w2.id in all_workflow_ids
    end

    test "fires downstream triggers even when own workflows failed" do
      {:ok, w1} =
        Workflows.create_workflow(%{
          name: "W1",
          status: "active",
          nodes: [%{@valid_node | module: "Zaq.Engine.Workflows.NonExistent"}],
          edges: []
        })

      w2 = create_workflow("W2")

      t1 = create_trigger(%{execution_mode: "serial", on_failure: "stop"})
      t2 = create_trigger()
      Workflows.assign_workflow_to_trigger(t1, w1)
      Workflows.assign_workflow_to_trigger(t2, w2)
      Workflows.chain_trigger(t1, t2)

      t1 = Workflows.get_trigger!(t1.id)
      {:ok, results} = TriggerExecutor.execute(t1, %{})
      all_workflow_ids = Enum.map(results, fn {wid, _} -> wid end)
      assert w2.id in all_workflow_ids
    end
  end
end
