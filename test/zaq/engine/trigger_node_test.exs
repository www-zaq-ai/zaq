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

  defp create_active_workflow(name) do
    {:ok, workflow} =
      Workflows.create_workflow(%{name: name, status: "active", nodes: [@valid_node], edges: []})

    workflow
  end

  defp create_trigger(event_name) do
    {:ok, trigger} = Workflows.create_trigger(%{event_name: event_name, enabled: true})
    trigger
  end

  defp build_event(name, request \\ %{}, assigns \\ %{}) do
    %Event{
      request: request,
      next_hop: nil,
      name: name,
      trace_id: Ecto.UUID.generate(),
      assigns: assigns
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

  describe "fire/2 — event payload propagation (Step 1)" do
    test "propagates incoming event payload into source_event.assigns.input" do
      trigger = create_trigger("payload_event")
      workflow = create_active_workflow("PayloadWorkflow")
      Workflows.assign_workflow_to_trigger(trigger, workflow)

      payload = %{"user_id" => 123, "email" => "test@example.com"}
      incoming_event = build_event(:payload_event, payload)

      assert :ok = TriggerNode.fire("payload_event", incoming_event)

      [run] = Workflows.list_runs(workflow.id)
      # JSONB round-trip converts atom keys to strings
      assert get_in(run.source_event.assigns, ["input", "event", "payload"]) == payload
    end

    test "preserves trace_id from incoming event" do
      trigger = create_trigger("trace_event")
      workflow = create_active_workflow("TraceWorkflow")
      Workflows.assign_workflow_to_trigger(trigger, workflow)

      trace_id = Ecto.UUID.generate()
      incoming_event = %{build_event(:trace_event) | trace_id: trace_id}

      assert :ok = TriggerNode.fire("trace_event", incoming_event)

      [run] = Workflows.list_runs(workflow.id)
      assert run.source_event.trace_id == trace_id
      assert get_in(run.source_event.assigns, ["input", "event", "trace_id"]) == trace_id
    end

    test "sets trigger_type and workflow_id in assigns" do
      trigger = create_trigger("assigns_event")
      workflow = create_active_workflow("AssignsWorkflow")
      Workflows.assign_workflow_to_trigger(trigger, workflow)

      assert :ok = TriggerNode.fire("assigns_event", build_event(:assigns_event))

      [run] = Workflows.list_runs(workflow.id)
      # JSONB round-trip converts atom keys to strings
      assert get_in(run.source_event.assigns, ["trigger_type"]) == "event"
      assert get_in(run.source_event.assigns, ["workflow_id"]) == workflow.id
    end

    test "handles nil request payload" do
      trigger = create_trigger("nil_payload_event")
      workflow = create_active_workflow("NilPayloadWorkflow")
      Workflows.assign_workflow_to_trigger(trigger, workflow)

      incoming_event = %{build_event(:nil_payload_event, nil) | request: nil}

      assert :ok = TriggerNode.fire("nil_payload_event", incoming_event)

      [run] = Workflows.list_runs(workflow.id)
      assert get_in(run.source_event.assigns, ["input", "event", "payload"]) == nil
    end

    test "handles empty assigns in incoming event" do
      trigger = create_trigger("empty_assigns_event")
      workflow = create_active_workflow("EmptyAssignsWorkflow")
      Workflows.assign_workflow_to_trigger(trigger, workflow)

      incoming_event = build_event(:empty_assigns_event, %{"data" => "value"}, %{})

      assert :ok = TriggerNode.fire("empty_assigns_event", incoming_event)

      [run] = Workflows.list_runs(workflow.id)
      assert get_in(run.source_event.assigns, ["input", "event", "assigns"]) == %{}
    end

    test "preserves incoming event assigns in input" do
      trigger = create_trigger("nested_assigns_event")
      workflow = create_active_workflow("NestedAssignsWorkflow")
      Workflows.assign_workflow_to_trigger(trigger, workflow)

      event_assigns = %{"context" => "important_value"}
      incoming_event = build_event(:nested_assigns_event, %{"data" => "value"}, event_assigns)

      assert :ok = TriggerNode.fire("nested_assigns_event", incoming_event)

      [run] = Workflows.list_runs(workflow.id)
      assert get_in(run.source_event.assigns, ["input", "event", "assigns"]) == event_assigns
    end

    test "JSONB round-trip: string-keyed assigns path" do
      alias Zaq.Types.WorkflowEvent
      trigger = create_trigger("roundtrip_event")
      workflow = create_active_workflow("RoundtripWorkflow")
      Workflows.assign_workflow_to_trigger(trigger, workflow)

      incoming_event = build_event(:roundtrip_event, %{"email" => "user@example.com"})

      assert :ok = TriggerNode.fire("roundtrip_event", incoming_event)

      [run] = Workflows.list_runs(workflow.id)
      source_event = run.source_event

      # Simulate JSONB dump and load (converts atom keys to strings)
      {:ok, dumped} = WorkflowEvent.dump(source_event)
      {:ok, reloaded} = WorkflowEvent.load(dumped)

      # Verify that the payload is still accessible via string keys after round-trip
      assert get_in(reloaded.assigns, ["input", "event", "payload"]) == %{
               "email" => "user@example.com"
             }
    end

    test "generates trace_id if not present in incoming event" do
      trigger = create_trigger("generate_trace_event")
      workflow = create_active_workflow("GenerateTraceWorkflow")
      Workflows.assign_workflow_to_trigger(trigger, workflow)

      incoming_event = %{build_event(:generate_trace_event) | trace_id: nil}

      assert :ok = TriggerNode.fire("generate_trace_event", incoming_event)

      [run] = Workflows.list_runs(workflow.id)
      assert run.source_event.trace_id != nil
      assert is_binary(run.source_event.trace_id)
    end

    test "logs and does not propagate when a workflow run fails to start" do
      trigger = create_trigger("failing_event")

      # Active workflow whose node references a non-existent module. It passes
      # creation (module is non-empty) and is returned by
      # list_workflows_for_trigger, but DagBuilder fails to resolve the module,
      # so start_run returns {:error, _} → exercises run_workflow's error branch.
      {:ok, bad_workflow} =
        Workflows.create_workflow(%{
          name: "BadModuleWorkflow",
          status: "active",
          nodes: [
            %{
              name: "boom",
              type: "action",
              module: "Zaq.Engine.Workflows.Test.DoesNotExist",
              params: %{},
              index: 0
            }
          ],
          edges: []
        })

      Workflows.assign_workflow_to_trigger(trigger, bad_workflow)

      # fire/2 still returns :ok — individual run failures are logged, not raised.
      assert :ok = TriggerNode.fire("failing_event", build_event(:failing_event))

      # The run was created (create_run succeeded) then marked failed when
      # start_run hit the DagBuilder module-resolution error.
      [run] = Workflows.list_runs(bad_workflow.id)
      assert run.status == "failed"
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
