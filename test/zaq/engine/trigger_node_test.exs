defmodule Zaq.Engine.TriggerNodeTest do
  use Zaq.DataCase, async: true

  alias Zaq.Engine.{TriggerNode, Workflows}
  alias Zaq.Event

  @valid_node %{
    name: "fetch",
    type: "action",
    module: "Zaq.Agent.Tools.Email.FetchEmails",
    params: %{},
    index: 0
  }

  defp create_active_workflow(name \\ "TestWorkflow") do
    {:ok, workflow} =
      Workflows.create_workflow(%{name: name, status: "active", nodes: [@valid_node], edges: []})

    workflow
  end

  defp create_trigger(event_name) do
    {:ok, trigger} = Workflows.create_trigger(%{event_name: event_name, enabled: true})
    trigger
  end

  defp build_event(name) do
    %Event{
      request: %{},
      next_hop: nil,
      name: name,
      trace_id: Ecto.UUID.generate()
    }
  end

  describe "fire/2 — empty workflow list" do
    test "returns :ok with no workflows linked to trigger" do
      # Trigger exists but no workflows assigned
      _trigger = create_trigger("no_workflows_event")

      assert :ok = TriggerNode.fire("no_workflows_event", build_event(:no_workflows_event))
    end
  end

  describe "fire/2 — workflow execution" do
    test "calls list_workflows_for_trigger with the event_name" do
      trigger = create_trigger("email_received")
      workflow = create_active_workflow("EmailWorkflow")
      Workflows.assign_workflow_to_trigger(trigger, workflow)

      # fire/2 internally calls list_workflows_for_trigger("email_received")
      # We verify by checking a run was created for the workflow
      assert :ok = TriggerNode.fire("email_received", build_event(:email_received))

      runs = Workflows.list_runs(workflow.id)
      assert runs != []
    end

    test "creates a run for each workflow linked to the trigger" do
      trigger = create_trigger("user_signed_up")
      w1 = create_active_workflow("Workflow1")
      w2 = create_active_workflow("Workflow2")
      Workflows.assign_workflow_to_trigger(trigger, w1)
      Workflows.assign_workflow_to_trigger(trigger, w2)

      assert :ok = TriggerNode.fire("user_signed_up", build_event(:user_signed_up))

      runs1 = Workflows.list_runs(w1.id)
      runs2 = Workflows.list_runs(w2.id)
      assert length(runs1) == 1
      assert length(runs2) == 1
    end

    test "excludes non-active (draft) workflows" do
      trigger = create_trigger("draft_event")

      {:ok, draft_workflow} =
        Workflows.create_workflow(%{
          name: "DraftWorkflow",
          status: "draft",
          nodes: [@valid_node],
          edges: []
        })

      Workflows.assign_workflow_to_trigger(trigger, draft_workflow)

      assert :ok = TriggerNode.fire("draft_event", build_event(:draft_event))

      # Draft workflow should have no runs created
      runs = Workflows.list_runs(draft_workflow.id)
      assert runs == []
    end

    test "excludes archived workflows" do
      trigger = create_trigger("archived_event")

      {:ok, archived_workflow} =
        Workflows.create_workflow(%{
          name: "ArchivedWorkflow",
          status: "archived",
          nodes: [@valid_node],
          edges: []
        })

      Workflows.assign_workflow_to_trigger(trigger, archived_workflow)

      assert :ok = TriggerNode.fire("archived_event", build_event(:archived_event))

      runs = Workflows.list_runs(archived_workflow.id)
      assert runs == []
    end
  end

  describe "list_workflows_for_trigger/1 (context function)" do
    test "returns active workflows linked to a trigger by event_name string" do
      trigger = create_trigger("context_test_event")
      w = create_active_workflow("ContextWorkflow")
      Workflows.assign_workflow_to_trigger(trigger, w)

      results = Workflows.list_workflows_for_trigger("context_test_event")
      ids = Enum.map(results, & &1.id)
      assert w.id in ids
    end

    test "returns empty list for unknown event_name" do
      results = Workflows.list_workflows_for_trigger("nonexistent_event_xyz")
      assert results == []
    end

    test "excludes non-active workflows" do
      trigger = create_trigger("status_filter_event")

      {:ok, draft_w} =
        Workflows.create_workflow(%{
          name: "DraftW",
          status: "draft",
          nodes: [@valid_node],
          edges: []
        })

      Workflows.assign_workflow_to_trigger(trigger, draft_w)

      results = Workflows.list_workflows_for_trigger("status_filter_event")
      ids = Enum.map(results, & &1.id)
      refute draft_w.id in ids
    end
  end
end
