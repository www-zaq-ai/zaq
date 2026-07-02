defmodule Zaq.Engine.TriggerNodeTest do
  use Zaq.DataCase, async: true

  alias Ecto.Adapters.SQL
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Engine.TriggerNode
  alias Zaq.Engine.Workflows
  alias Zaq.Event
  alias Zaq.Repo

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

      assert :ok = TriggerNode.fire("engine:no_workflows_event", build_event(:no_workflows_event))
    end
  end

  describe "fire/2 — workflow execution" do
    test "calls list_workflows_for_trigger with the event_name" do
      trigger = create_trigger("email_received")
      workflow = create_active_workflow("EmailWorkflow")
      Workflows.assign_workflow_to_trigger(trigger, workflow)

      # fire/2 internally calls list_workflows_for_trigger("engine:email_received")
      # We verify by checking a run was created for the workflow
      assert :ok = TriggerNode.fire("engine:email_received", build_event(:email_received))

      runs = Workflows.list_runs(workflow.id)
      assert runs != []
    end

    test "creates a run for each workflow linked to the trigger" do
      trigger = create_trigger("user_signed_up")
      w1 = create_active_workflow("Workflow1")
      w2 = create_active_workflow("Workflow2")
      Workflows.assign_workflow_to_trigger(trigger, w1)
      Workflows.assign_workflow_to_trigger(trigger, w2)

      assert :ok = TriggerNode.fire("engine:user_signed_up", build_event(:user_signed_up))

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

      assert :ok = TriggerNode.fire("engine:draft_event", build_event(:draft_event))

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

      assert :ok = TriggerNode.fire("engine:archived_event", build_event(:archived_event))

      runs = Workflows.list_runs(archived_workflow.id)
      assert runs == []
    end
  end

  describe "fire/2 — event payload propagation" do
    test "passes request payload directly as input (not wrapped in event map)" do
      trigger = create_trigger("direct_payload_event")
      workflow = create_active_workflow("DirectPayloadWorkflow")
      Workflows.assign_workflow_to_trigger(trigger, workflow)

      payload = %{"email" => "lead@example.com", "name" => "John"}
      incoming_event = build_event(:direct_payload_event, payload)

      assert :ok = TriggerNode.fire("engine:direct_payload_event", incoming_event)

      [run] = Workflows.list_runs(workflow.id)
      assert get_in(run.source_event.assigns, ["input"]) == payload
    end

    test "propagates incoming event payload into source_event.assigns.input" do
      trigger = create_trigger("payload_event")
      workflow = create_active_workflow("PayloadWorkflow")
      Workflows.assign_workflow_to_trigger(trigger, workflow)

      payload = %{"user_id" => 123, "email" => "test@example.com"}
      incoming_event = build_event(:payload_event, payload)

      assert :ok = TriggerNode.fire("engine:payload_event", incoming_event)

      [run] = Workflows.list_runs(workflow.id)
      assert get_in(run.source_event.assigns, ["input"]) == payload
    end

    test "preserves trace_id from incoming event" do
      trigger = create_trigger("trace_event")
      workflow = create_active_workflow("TraceWorkflow")
      Workflows.assign_workflow_to_trigger(trigger, workflow)

      trace_id = Ecto.UUID.generate()
      incoming_event = %{build_event(:trace_event) | trace_id: trace_id}

      assert :ok = TriggerNode.fire("engine:trace_event", incoming_event)

      [run] = Workflows.list_runs(workflow.id)
      assert run.source_event.trace_id == trace_id
    end

    test "sets trigger_type and workflow_id in assigns" do
      trigger = create_trigger("assigns_event")
      workflow = create_active_workflow("AssignsWorkflow")
      Workflows.assign_workflow_to_trigger(trigger, workflow)

      assert :ok = TriggerNode.fire("engine:assigns_event", build_event(:assigns_event))

      [run] = Workflows.list_runs(workflow.id)
      assert get_in(run.source_event.assigns, ["trigger_type"]) == "event"
      assert get_in(run.source_event.assigns, ["workflow_id"]) == workflow.id
    end

    test "handles nil request payload — defaults to empty map" do
      trigger = create_trigger("nil_payload_event")
      workflow = create_active_workflow("NilPayloadWorkflow")
      Workflows.assign_workflow_to_trigger(trigger, workflow)

      incoming_event = %{build_event(:nil_payload_event, nil) | request: nil}

      assert :ok = TriggerNode.fire("engine:nil_payload_event", incoming_event)

      [run] = Workflows.list_runs(workflow.id)
      assert get_in(run.source_event.assigns, ["input"]) == %{}
    end

    test "JSONB round-trip: string-keyed assigns path" do
      alias Zaq.Types.WorkflowEvent
      trigger = create_trigger("roundtrip_event")
      workflow = create_active_workflow("RoundtripWorkflow")
      Workflows.assign_workflow_to_trigger(trigger, workflow)

      incoming_event = build_event(:roundtrip_event, %{"email" => "user@example.com"})

      assert :ok = TriggerNode.fire("engine:roundtrip_event", incoming_event)

      [run] = Workflows.list_runs(workflow.id)
      source_event = run.source_event

      {:ok, dumped} = WorkflowEvent.dump(source_event)
      {:ok, reloaded} = WorkflowEvent.load(dumped)

      assert get_in(reloaded.assigns, ["input"]) == %{"email" => "user@example.com"}
    end

    test "generates trace_id if not present in incoming event" do
      trigger = create_trigger("generate_trace_event")
      workflow = create_active_workflow("GenerateTraceWorkflow")
      Workflows.assign_workflow_to_trigger(trigger, workflow)

      incoming_event = %{build_event(:generate_trace_event) | trace_id: nil}

      assert :ok = TriggerNode.fire("engine:generate_trace_event", incoming_event)

      [run] = Workflows.list_runs(workflow.id)
      assert run.source_event.trace_id != nil
      assert is_binary(run.source_event.trace_id)
    end

    test "logs and does not propagate when a workflow run fails to start" do
      trigger = create_trigger("failing_event")

      bad_workflow = create_active_workflow("BadModuleWorkflow")

      # Save-time validation rejects unknown action modules. This bypasses the
      # changeset to simulate code drift after a workflow has already been saved:
      # list_workflows_for_trigger still returns it, but DagBuilder fails to
      # resolve the module when the run starts.
      nodes = [
        %{
          "name" => "boom",
          "type" => "action",
          "module" => "Zaq.Engine.Workflows.Test.DoesNotExist",
          "params" => %{},
          "index" => 0
        }
      ]

      nodes_json = Jason.encode!(nodes)

      SQL.query!(
        Repo,
        "UPDATE workflows SET nodes = '#{nodes_json}'::jsonb WHERE id::text = $1",
        [bad_workflow.id]
      )

      Workflows.assign_workflow_to_trigger(trigger, bad_workflow)

      # fire/2 still returns :ok — individual run failures are logged, not raised.
      assert :ok = TriggerNode.fire("engine:failing_event", build_event(:failing_event))

      # The run was created (create_run succeeded) then marked failed when
      # start_run hit the DagBuilder module-resolution error.
      [run] = Workflows.list_runs(bad_workflow.id)
      assert run.status == "failed"
    end
  end

  describe "fire/2 — actor and machine-marker propagation" do
    test "propagates the incoming event actor into source_event.actor" do
      trigger = create_trigger("actor_event")
      workflow = create_active_workflow("ActorWorkflow")
      Workflows.assign_workflow_to_trigger(trigger, workflow)

      actor = %{id: "u1", name: "alice", person: %{id: 42}}
      incoming_event = %{build_event(:actor_event) | actor: actor}

      assert :ok = TriggerNode.fire("engine:actor_event", incoming_event)

      [run] = Workflows.list_runs(workflow.id)
      stored = run.source_event.actor
      person = stored["person"] || stored[:person]
      assert person["id"] == 42 or person[:id] == 42
    end

    test "derives source_event.actor from incoming request person when broadcast actor is absent" do
      trigger = create_trigger("incoming_person_event")
      workflow = create_active_workflow("IncomingPersonWorkflow")
      Workflows.assign_workflow_to_trigger(trigger, workflow)

      incoming = %Incoming{
        content: "hello",
        channel_id: "c1",
        provider: :mattermost,
        person: %{id: 42, full_name: "Alice", team_ids: [7]}
      }

      incoming_event = %{build_event(:incoming_person_event) | request: incoming, actor: nil}

      assert :ok = TriggerNode.fire("engine:incoming_person_event", incoming_event)

      [run] = Workflows.list_runs(workflow.id)
      stored = run.source_event.actor
      person = stored["person"] || stored[:person]
      assert person["id"] == 42 or person[:id] == 42
      assert person["team_ids"] == [7] or person[:team_ids] == [7]
    end

    test "actor stays nil for actorless events — never fabricated" do
      trigger = create_trigger("actorless_event")
      workflow = create_active_workflow("ActorlessWorkflow")
      Workflows.assign_workflow_to_trigger(trigger, workflow)

      assert :ok = TriggerNode.fire("engine:actorless_event", build_event(:actorless_event))

      [run] = Workflows.list_runs(workflow.id)
      assert is_nil(run.source_event.actor)
    end

    test "explicit machine marker sets skip_permissions in assigns" do
      trigger = create_trigger("machine_event")
      workflow = create_active_workflow("MachineWorkflow")
      Workflows.assign_workflow_to_trigger(trigger, workflow)

      incoming_event = build_event(:machine_event, %{trigger_id: 7, machine: true})

      assert :ok = TriggerNode.fire("engine:machine_event", incoming_event)

      [run] = Workflows.list_runs(workflow.id)
      assert get_in(run.source_event.assigns, ["skip_permissions"]) == true
    end

    test "string-keyed machine marker is honored (JSONB-shaped payload)" do
      trigger = create_trigger("machine_string_event")
      workflow = create_active_workflow("MachineStringWorkflow")
      Workflows.assign_workflow_to_trigger(trigger, workflow)

      incoming_event = build_event(:machine_string_event, %{"machine" => true})

      assert :ok = TriggerNode.fire("engine:machine_string_event", incoming_event)

      [run] = Workflows.list_runs(workflow.id)
      assert get_in(run.source_event.assigns, ["skip_permissions"]) == true
    end

    test "no marker means no bypass — even when the actor is nil" do
      trigger = create_trigger("no_bypass_event")
      workflow = create_active_workflow("NoBypassWorkflow")
      Workflows.assign_workflow_to_trigger(trigger, workflow)

      assert :ok = TriggerNode.fire("engine:no_bypass_event", build_event(:no_bypass_event))

      [run] = Workflows.list_runs(workflow.id)
      assert get_in(run.source_event.assigns, ["skip_permissions"]) == false
    end

    test "a truthy-but-not-true marker does not grant bypass" do
      trigger = create_trigger("sneaky_marker_event")
      workflow = create_active_workflow("SneakyMarkerWorkflow")
      Workflows.assign_workflow_to_trigger(trigger, workflow)

      incoming_event = build_event(:sneaky_marker_event, %{"machine" => "yes"})

      assert :ok = TriggerNode.fire("engine:sneaky_marker_event", incoming_event)

      [run] = Workflows.list_runs(workflow.id)
      assert get_in(run.source_event.assigns, ["skip_permissions"]) == false
    end
  end

  describe "list_workflows_for_trigger/1 (context function)" do
    test "returns active workflows linked to a trigger by event_name string" do
      trigger = create_trigger("context_test_event")
      w = create_active_workflow("ContextWorkflow")
      Workflows.assign_workflow_to_trigger(trigger, w)

      results = Workflows.list_workflows_for_trigger("engine:context_test_event")
      ids = Enum.map(results, & &1.id)
      assert w.id in ids
    end

    test "returns empty list for unknown event_name" do
      results = Workflows.list_workflows_for_trigger("engine:nonexistent_event_xyz")
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

      results = Workflows.list_workflows_for_trigger("engine:status_filter_event")
      ids = Enum.map(results, & &1.id)
      refute draft_w.id in ids
    end
  end
end
