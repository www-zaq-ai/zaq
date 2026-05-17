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
end
