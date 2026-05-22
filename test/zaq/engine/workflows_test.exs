defmodule Zaq.Engine.WorkflowsTest do
  use Zaq.DataCase, async: true

  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.Trigger
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

  defp create_workflow(attrs \\ %{}) do
    {:ok, w} =
      Workflows.create_workflow(
        Map.merge(%{name: "W", status: "draft", nodes: [@valid_node], edges: []}, attrs)
      )

    w
  end

  defp create_trigger(attrs \\ %{}) do
    {:ok, t} = Workflows.create_trigger(Map.merge(%{event_name: "manual_trigger"}, attrs))
    t
  end

  # --- list_triggers/1 ---

  describe "list_triggers/1" do
    test "returns all triggers regardless of workflow" do
      t1 = create_trigger(%{event_name: "trigger_a"})
      t2 = create_trigger(%{event_name: "trigger_b"})
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
      t2 = create_trigger(%{event_name: "other_event"})
      Workflows.assign_workflow_to_trigger(t1, w1)
      Workflows.assign_workflow_to_trigger(t2, w2)

      result = Workflows.list_triggers_for_workflow(w1.id)
      ids = Enum.map(result, & &1.id)
      assert t1.id in ids
      refute t2.id in ids
    end

    test "returns triggers ordered by position" do
      w = create_workflow()
      t1 = create_trigger(%{event_name: "event_pos1"})
      t2 = create_trigger(%{event_name: "event_pos2"})
      Workflows.assign_workflow_to_trigger(t1, w, position: 1)
      Workflows.assign_workflow_to_trigger(t2, w, position: 0)

      [first, second] = Workflows.list_triggers_for_workflow(w.id)
      assert first.id == t2.id
      assert second.id == t1.id
    end
  end

  # --- list_trigger_event_names/0 ---

  describe "list_trigger_event_names/0" do
    test "returns list of enabled trigger event_names" do
      create_trigger(%{event_name: "enabled_event_1", enabled: true})
      create_trigger(%{event_name: "enabled_event_2", enabled: true})

      names = Workflows.list_trigger_event_names()
      assert "enabled_event_1" in names
      assert "enabled_event_2" in names
    end

    test "excludes disabled triggers" do
      create_trigger(%{event_name: "enabled_ok", enabled: true})
      create_trigger(%{event_name: "disabled_skip", enabled: false})

      names = Workflows.list_trigger_event_names()
      assert "enabled_ok" in names
      refute "disabled_skip" in names
    end

    test "returns empty list when no enabled triggers" do
      create_trigger(%{event_name: "some_event", enabled: false})
      assert [] = Workflows.list_trigger_event_names()
    end
  end

  # --- create_trigger/2 ---

  describe "create_trigger/2" do
    test "creates a trigger with event_name" do
      assert {:ok, %Trigger{} = t} = Workflows.create_trigger(%{event_name: "order_created"})
      assert t.event_name == "order_created"
      assert t.enabled == true
    end

    test "rejects trigger without event_name" do
      assert {:error, cs} = Workflows.create_trigger(%{})
      assert "can't be blank" in errors_on(cs).event_name
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

  # --- delete_trigger/2 ---

  describe "delete_trigger/2" do
    test "deletes trigger and cascades to trigger_workflows" do
      t = create_trigger()
      w = create_workflow()
      Workflows.assign_workflow_to_trigger(t, w)
      assert {:ok, _} = Workflows.delete_trigger(t)
      assert [] = Workflows.list_triggers_for_workflow(w.id)
    end

    test "deletes a standalone trigger" do
      t = create_trigger()
      assert {:ok, _} = Workflows.delete_trigger(t)
      remaining_ids = Workflows.list_triggers() |> Enum.map(& &1.id)
      refute t.id in remaining_ids
    end
  end

  # --- update_trigger/3 — registry sync ---

  describe "update_trigger/3 — registry sync" do
    test "update_trigger succeeds without crashing when EventRegistry is not running" do
      # DataCase does not start the Engine supervisor, so Process.whereis(EventRegistry) == nil.
      # The sync_registry/1 guard means no call is made — update_trigger must not crash.
      t = create_trigger(%{event_name: "sync_test_event", enabled: true})
      assert {:ok, updated} = Workflows.update_trigger(t, %{enabled: false})
      assert updated.enabled == false
    end

    test "disabling a trigger deactivates the event when EventRegistry is not running" do
      # Verifies the correct DB value is returned even without a live registry.
      {:ok, trigger} = Workflows.create_trigger(%{event_name: "deactivate_me", enabled: true})
      assert {:ok, updated} = Workflows.update_trigger(trigger, %{enabled: false})
      assert updated.enabled == false
    end

    test "enabling a trigger activates the event when EventRegistry is not running" do
      {:ok, trigger} = Workflows.create_trigger(%{event_name: "activate_me", enabled: false})
      assert {:ok, updated} = Workflows.update_trigger(trigger, %{enabled: true})
      assert updated.enabled == true
    end
  end

  # --- count_runs/1 ---

  describe "count_runs/1" do
    test "returns 0 for a workflow with no runs" do
      w = create_workflow()
      assert Workflows.count_runs(w.id) == 0
    end

    test "returns the correct count" do
      w = create_workflow()
      create_run(w)
      create_run(w)
      assert Workflows.count_runs(w.id) == 2
    end

    test "counts only runs belonging to the given workflow" do
      w1 = create_workflow(%{name: "W1"})
      w2 = create_workflow(%{name: "W2"})
      create_run(w1)
      create_run(w1)
      create_run(w2)
      assert Workflows.count_runs(w1.id) == 2
      assert Workflows.count_runs(w2.id) == 1
    end
  end

  # --- list_runs/2 pagination ---

  describe "list_runs/2 with pagination opts" do
    test "returns all runs when no limit given" do
      w = create_workflow()
      for _ <- 1..5, do: create_run(w)
      assert length(Workflows.list_runs(w.id)) == 5
    end

    test "respects the limit option" do
      w = create_workflow()
      for _ <- 1..5, do: create_run(w)
      assert length(Workflows.list_runs(w.id, limit: 3)) == 3
    end

    test "pages do not overlap" do
      w = create_workflow()
      for _ <- 1..5, do: create_run(w)
      page1_ids = Workflows.list_runs(w.id, limit: 3, offset: 0) |> Enum.map(& &1.id)
      page2_ids = Workflows.list_runs(w.id, limit: 3, offset: 3) |> Enum.map(& &1.id)
      assert length(page1_ids) == 3
      assert length(page2_ids) == 2
      assert MapSet.disjoint?(MapSet.new(page1_ids), MapSet.new(page2_ids))
    end

    test "pages cover all runs" do
      w = create_workflow()
      for _ <- 1..5, do: create_run(w)
      all_ids = Workflows.list_runs(w.id) |> Enum.map(& &1.id) |> MapSet.new()
      page1_ids = Workflows.list_runs(w.id, limit: 3, offset: 0) |> Enum.map(& &1.id)
      page2_ids = Workflows.list_runs(w.id, limit: 3, offset: 3) |> Enum.map(& &1.id)
      paged_ids = MapSet.new(page1_ids ++ page2_ids)
      assert MapSet.equal?(all_ids, paged_ids)
    end
  end

  # --- list_workflows_with_run_counts_and_triggers/0 ---

  describe "list_workflows_with_run_counts_and_triggers/0" do
    test "returns empty list when no workflows exist" do
      assert [] = Workflows.list_workflows_with_run_counts_and_triggers()
    end

    test "returns {workflow, run_count, triggers} tuples" do
      w = create_workflow()
      t = create_trigger()
      Workflows.assign_workflow_to_trigger(t, w)
      create_run(w)

      [{workflow, count, triggers}] = Workflows.list_workflows_with_run_counts_and_triggers()
      assert workflow.id == w.id
      assert count == 1
      assert [trigger] = triggers
      assert trigger.id == t.id
    end

    test "returns zero count and empty triggers when workflow has none" do
      w = create_workflow()
      [{workflow, count, triggers}] = Workflows.list_workflows_with_run_counts_and_triggers()
      assert workflow.id == w.id
      assert count == 0
      assert triggers == []
    end

    test "results are ordered by workflow name ascending" do
      create_workflow(%{name: "Zebra"})
      create_workflow(%{name: "Alpha"})
      create_workflow(%{name: "Middle"})
      results = Workflows.list_workflows_with_run_counts_and_triggers()
      names = Enum.map(results, fn {w, _, _} -> w.name end)
      assert names == Enum.sort(names)
    end

    test "counts are correct per workflow" do
      w1 = create_workflow(%{name: "W1"})
      w2 = create_workflow(%{name: "W2"})
      create_run(w1)
      create_run(w1)
      create_run(w2)

      results =
        Map.new(Workflows.list_workflows_with_run_counts_and_triggers(), fn {w, c, _} ->
          {w.id, c}
        end)

      assert results[w1.id] == 2
      assert results[w2.id] == 1
    end
  end

  # --- export_workflow/1 ---

  describe "export_workflow/1" do
    test "returns a map with all workflow fields" do
      w = create_workflow(%{name: "Export Me", description: "desc"})
      data = Workflows.export_workflow(w)
      assert data["name"] == "Export Me"
      assert data["description"] == "desc"
      assert is_list(data["nodes"])
      assert is_list(data["edges"])
      assert is_map(data["settings"])
    end

    test "includes required node fields" do
      w = create_workflow()
      [node] = Workflows.export_workflow(w)["nodes"]
      assert Map.has_key?(node, "name")
      assert Map.has_key?(node, "type")
      assert Map.has_key?(node, "module")
      assert Map.has_key?(node, "index")
      assert Map.has_key?(node, "params")
    end

    test "export output is JSON encodable" do
      w = create_workflow()
      data = Workflows.export_workflow(w)
      assert {:ok, _json} = Jason.encode(data)
    end

    test "round-trip: export then import recreates the workflow" do
      original = create_workflow(%{name: "Round Trip", status: "active"})
      exported = Workflows.export_workflow(original)
      assert {:ok, imported} = Workflows.import_workflow(exported)
      assert imported.name == original.name
    end
  end

  # --- import_workflow/1 ---

  describe "import_workflow/1" do
    test "creates a workflow from a valid exported map" do
      original = create_workflow(%{name: "Import Test", status: "active"})
      exported = Workflows.export_workflow(original)
      assert {:ok, imported} = Workflows.import_workflow(exported)
      assert imported.name == "Import Test"
    end

    test "always sets status to draft regardless of exported status" do
      w = create_workflow(%{name: "Was Active", status: "active"})
      exported = Workflows.export_workflow(w)
      assert {:ok, imported} = Workflows.import_workflow(exported)
      assert imported.status == "draft"
    end

    test "preserves nodes on import" do
      w = create_workflow()
      exported = Workflows.export_workflow(w)
      assert {:ok, imported} = Workflows.import_workflow(exported)
      assert length(imported.nodes) == length(w.nodes)
    end

    test "returns error changeset for missing name" do
      assert {:error, %Ecto.Changeset{} = cs} =
               Workflows.import_workflow(%{"nodes" => [], "edges" => []})

      assert "can't be blank" in errors_on(cs).name
    end

    test "returns error changeset for empty map" do
      assert {:error, %Ecto.Changeset{}} = Workflows.import_workflow(%{})
    end
  end

  # --- list_triggers_with_workflows_and_recent_runs/1 ---

  describe "list_triggers_with_workflows_and_recent_runs/1" do
    test "returns empty list when no triggers" do
      assert [] = Workflows.list_triggers_with_workflows_and_recent_runs()
    end

    test "returns trigger with empty workflows list when none assigned" do
      t = create_trigger(%{event_name: "evt.none"})
      result = Workflows.list_triggers_with_workflows_and_recent_runs()
      assert [{^t, []}] = result
    end

    test "returns workflows assigned to trigger" do
      t = create_trigger(%{event_name: "evt.wf"})
      w = create_workflow(%{name: "WF1"})
      Workflows.assign_workflow_to_trigger(t, w)

      [{_trigger, enriched}] = Workflows.list_triggers_with_workflows_and_recent_runs()
      assert [%{workflow: wf, recent_runs: _}] = enriched
      assert wf.id == w.id
    end

    test "includes recent runs for each workflow" do
      t = create_trigger(%{event_name: "evt.runs"})
      w = create_workflow(%{name: "WF-R"})
      Workflows.assign_workflow_to_trigger(t, w)
      run = create_run(w)

      [{_trigger, [%{workflow: _, recent_runs: runs}]}] =
        Workflows.list_triggers_with_workflows_and_recent_runs()

      assert Enum.any?(runs, &(&1.id == run.id))
    end

    test "respects limit option" do
      t = create_trigger(%{event_name: "evt.limit"})
      w = create_workflow(%{name: "WF-L"})
      Workflows.assign_workflow_to_trigger(t, w)
      Enum.each(1..4, fn _ -> create_run(w) end)

      [{_trigger, [%{recent_runs: runs}]}] =
        Workflows.list_triggers_with_workflows_and_recent_runs(limit: 2)

      assert length(runs) == 2
    end

    test "includes disabled triggers" do
      create_trigger(%{event_name: "evt.disabled", enabled: false})
      result = Workflows.list_triggers_with_workflows_and_recent_runs()
      assert length(result) == 1
    end

    test "multiple triggers are returned sorted by inserted_at desc" do
      t1 = create_trigger(%{event_name: "evt.first"})
      t2 = create_trigger(%{event_name: "evt.second"})

      [{first, _}, {second, _}] = Workflows.list_triggers_with_workflows_and_recent_runs()
      assert first.id == t2.id
      assert second.id == t1.id
    end

    test "runs appear only for the workflow that has them" do
      t = create_trigger(%{event_name: "evt.split"})
      w1 = create_workflow(%{name: "W1"})
      w2 = create_workflow(%{name: "W2"})
      Workflows.assign_workflow_to_trigger(t, w1)
      Workflows.assign_workflow_to_trigger(t, w2)
      _run = create_run(w1)

      [{_trigger, enriched}] = Workflows.list_triggers_with_workflows_and_recent_runs()
      w1_entry = Enum.find(enriched, &(&1.workflow.id == w1.id))
      w2_entry = Enum.find(enriched, &(&1.workflow.id == w2.id))

      assert length(w1_entry.recent_runs) == 1
      assert w2_entry.recent_runs == []
    end
  end

  # --- delete_workflow/1 ---

  describe "delete_workflow/1" do
    test "removes the workflow" do
      w = create_workflow()
      assert {:ok, _} = Workflows.delete_workflow(w)
      refute Workflows.list_workflows() |> Enum.any?(&(&1.id == w.id))
    end

    test "does not affect other workflows" do
      w1 = create_workflow(%{name: "Keep"})
      w2 = create_workflow(%{name: "Delete"})
      Workflows.delete_workflow(w2)
      assert Workflows.list_workflows() |> Enum.any?(&(&1.id == w1.id))
    end

    test "also removes associated runs and their step records" do
      w = create_workflow()
      run = create_run(w)
      assert {:ok, _} = Workflows.delete_workflow(w)
      assert is_nil(Workflows.get_run(run.id))
    end
  end
end
