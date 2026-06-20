defmodule Zaq.Engine.Workflows.EmailReplyWorkflowDispatchTest do
  @moduledoc """
  End-to-end test for the email reply workflow dispatched through TriggerNode.

  Flow:
    create_workflow → create_trigger → assign_trigger → TriggerNode.fire
    → Workflows.create_run → Workflows.start_run → WorkflowRunAgent.execute

  Four scenarios, one per describe block:
    1. Emails found, fast draft  → run suspends at review_draft ("waiting")
    2. No emails                 → notify runs, run completes ("completed")
    3. Emails found, slow draft  → draft times out, run fails ("failed")
    4. Emails found, HITL approved → full workflow completes ("completed")

  Every test asserts on the cascade results stored in each step run, verifying
  that data flows correctly through the DAG. Results are read from the DB via
  Workflows.list_step_runs/1, so all keys are string-keyed (JSONB round-trip)
  and atom values like :skipped/:sent become their string equivalents.
  """
  use Zaq.DataCase, async: false

  alias Zaq.Engine.{TriggerNode, Workflows}
  alias Zaq.Engine.Workflows.Steps.HumanInTheLoop
  alias Zaq.Event

  alias Zaq.Engine.Workflows.Test.{
    DraftReplyErrorStub,
    DraftReplyStub,
    EmptyInboxNotificationStub,
    EnsurePersonStub,
    InboxEmpty,
    InboxWithResults,
    SendReplyStub,
    WaitingAction
  }

  setup do
    stub(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{} = event -> event end)
    :ok
  end

  @event_name "engine:mail_responder_test"
  @notify_address "test@example.com"
  @draft_timeout_ms 200

  # Expected data matching the hardcoded outputs of InboxWithResults
  # and DraftReplyStub. All keys are strings (JSONB round-trip).
  @alice_email %{
    "message_id" => "test-001@example.com",
    "from" => %{"name" => "Alice", "address" => "alice@example.com"},
    "subject" => "Question about your service",
    "body_text" => "Hello, I have a question about your pricing."
  }

  @alice_draft %{
    "to_address" => "alice@example.com",
    "to_name" => "Alice",
    "subject" => "Re: Question about your service",
    "draft" => "Thank you for your email. We will get back to you shortly.",
    "message_id" => "test-001@example.com"
  }

  @edges [
    %{from: "fetch", to: "draft", condition: %{"field" => "count", "op" => "gt", "value" => 0}},
    %{from: "fetch", to: "notify", condition: %{"field" => "count", "op" => "eq", "value" => 0}},
    %{from: "draft", to: "review_draft"},
    %{from: "review_draft", to: "ensure_person"},
    %{from: "ensure_person", to: "send_reply"}
  ]

  # Sets up the full trigger chain:
  #   1. Creates the workflow with the given fetch module and draft delay.
  #   2. Creates a trigger for @event_name and links it to the workflow.
  # Returns {workflow, trigger}.
  defp setup_workflow(fetch_module, draft_delay_ms, draft_module \\ DraftReplyStub) do
    nodes = [
      %{
        name: "fetch",
        type: "action",
        module: inspect(fetch_module),
        params: %{"mailbox" => "test"},
        index: 0
      },
      %{
        name: "draft",
        type: "action",
        module: inspect(draft_module),
        params: %{"delay_ms" => draft_delay_ms, "timeout_ms" => @draft_timeout_ms},
        index: 1
      },
      %{
        name: "notify",
        type: "action",
        module: inspect(EmptyInboxNotificationStub),
        params: %{"notify_address" => @notify_address},
        index: 1
      },
      %{
        name: "review_draft",
        type: "action",
        module: inspect(WaitingAction),
        params: %{},
        index: 2
      },
      %{
        name: "ensure_person",
        type: "action",
        module: inspect(EnsurePersonStub),
        params: %{},
        index: 3
      },
      %{
        name: "send_reply",
        type: "action",
        module: inspect(SendReplyStub),
        params: %{},
        index: 4
      }
    ]

    {:ok, workflow} =
      Workflows.create_workflow(%{
        name: "Mail Responder Test #{System.unique_integer()}",
        status: "active",
        nodes: nodes,
        edges: @edges
      })

    {:ok, trigger} =
      Workflows.create_trigger(%{event_name: @event_name, enabled: true})

    {:ok, _} = Workflows.assign_workflow_to_trigger(trigger, workflow)

    {workflow, trigger}
  end

  # Fires the event synchronously through TriggerNode (the same function
  # EventRegistry calls when a matching event is dispatched via NodeRouter).
  defp fire do
    event = %Event{
      request: nil,
      next_hop: nil,
      name: :mail_responder_test,
      trace_id: Ecto.UUID.generate(),
      assigns: %{}
    }

    TriggerNode.fire(@event_name, event)
  end

  defp latest_run(workflow) do
    workflow.id
    |> Workflows.list_runs()
    |> List.first()
  end

  defp step_runs(run) do
    run.id
    |> Workflows.list_step_runs()
    |> Map.new(&{&1.step_name, &1})
  end

  # Returns log_summary timeline entries keyed by step_name.
  # Edge steps and action steps both appear — ordered by step_index in DB.
  defp log_timeline(run) do
    Map.new(run.log_summary["timeline"] || [], &{&1["step_name"], &1})
  end

  # ---------------------------------------------------------------------------
  # Path 1: emails found, draft responds within timeout
  # ---------------------------------------------------------------------------

  describe "emails found — fast response" do
    test "creates a run and suspends at review_draft (HITL)" do
      {workflow, _trigger} = setup_workflow(InboxWithResults, 0)
      test_pid = self()

      stub(Zaq.NodeRouterMock, :dispatch, fn %Event{} = event ->
        send(test_pid, {:dispatched, event})
        event
      end)

      assert :ok = fire()

      run = latest_run(workflow)
      assert run.status == "waiting"

      assert_received {:dispatched,
                       %Event{name: :workflow, request: %{action: "run.started"}} = event}

      assert event.request[:run_id] == run.id
      assert event.request[:workflow_id] == workflow.id
      assert event.next_hop.destination == :engine

      by_name = step_runs(run)

      # fetch: emails found, cascade seeded
      assert by_name["fetch"].status == "completed"
      assert by_name["fetch"].results["count"] == 1
      assert by_name["fetch"].results["emails"] == [@alice_email]
      assert by_name["fetch"].results["__cascade__"]["fetch"]["count"] == 1

      # conditional edges: draft path taken, notify path skipped
      assert by_name["fetch__to__draft__edge"].status == "completed"
      assert by_name["fetch__to__notify__edge"].status == "skipped"

      # draft: reply generated, cascade extended
      assert by_name["draft"].status == "completed"
      assert by_name["draft"].results["drafts"] == [@alice_draft]
      assert by_name["draft"].results["__cascade__"]["fetch"]["count"] == 1
      assert by_name["draft"].results["__cascade__"]["draft"]["drafts"] == [@alice_draft]

      # review_draft: suspended for HITL approval, no results stored yet
      assert by_name["review_draft"].status == "waiting"
      assert by_name["review_draft"].results == nil

      # log_summary: 5 steps captured before any approval
      # (fetch · 2 edge steps · draft · review_draft:waiting)
      log = run.log_summary
      assert log["step_count"] == 5
      assert log["failed_step_count"] == 0
      assert log["failed_steps"] == []

      lt = log_timeline(run)
      assert lt["fetch"]["status"] == "completed"
      assert lt["fetch__to__draft__edge"]["status"] == "completed"
      assert lt["fetch__to__notify__edge"]["status"] == "skipped"
      assert lt["draft"]["status"] == "completed"
      assert lt["review_draft"]["status"] == "waiting"
    end

    test "fetch and draft complete before HITL suspension" do
      {workflow, _trigger} = setup_workflow(InboxWithResults, 0)

      :ok = fire()

      run = latest_run(workflow)
      by_name = step_runs(run)

      # fetch
      assert by_name["fetch"].status == "completed"
      assert by_name["fetch"].results["count"] == 1
      assert by_name["fetch"].results["emails"] == [@alice_email]
      assert by_name["fetch"].results["__cascade__"]["fetch"]["count"] == 1

      # draft
      assert by_name["draft"].status == "completed"
      assert by_name["draft"].results["drafts"] == [@alice_draft]
      assert by_name["draft"].results["__cascade__"]["fetch"]["count"] == 1
      assert by_name["draft"].results["__cascade__"]["draft"]["drafts"] == [@alice_draft]

      # review_draft: suspended, no stored results
      assert by_name["review_draft"].status == "waiting"
      assert by_name["review_draft"].results == nil

      # log_summary builds up: after draft tick=4, after review_draft tick=5
      log = run.log_summary
      assert log["step_count"] == 5

      lt = log_timeline(run)
      assert lt["fetch"]["status"] == "completed"
      assert lt["draft"]["status"] == "completed"
      assert lt["review_draft"]["status"] == "waiting"
    end

    test "notify branch is not executed when emails are present" do
      {workflow, _trigger} = setup_workflow(InboxWithResults, 0)

      :ok = fire()

      run = latest_run(workflow)
      by_name = step_runs(run)

      # notify never ran
      refute Map.has_key?(by_name, "notify")

      # edge routing recorded correctly
      assert by_name["fetch__to__draft__edge"].status == "completed"
      assert by_name["fetch__to__notify__edge"].status == "skipped"
      assert by_name["fetch__to__notify__edge"].results["field"] == "count"
      assert by_name["fetch__to__notify__edge"].results["op"] == "eq"

      # log_summary: notify absent, skipped edge captured
      lt = log_timeline(run)
      assert lt["fetch__to__notify__edge"]["status"] == "skipped"
      assert lt["fetch__to__draft__edge"]["status"] == "completed"
      refute Map.has_key?(lt, "notify")
    end
  end

  # ---------------------------------------------------------------------------
  # Path 2: no emails
  # ---------------------------------------------------------------------------

  describe "no emails — notify branch" do
    test "creates a run and completes after notifying" do
      {workflow, _trigger} = setup_workflow(InboxEmpty, 0)

      assert :ok = fire()

      run = latest_run(workflow)
      assert run.status == "completed"

      by_name = step_runs(run)

      # fetch: empty mailbox, cascade seeded
      assert by_name["fetch"].status == "completed"
      assert by_name["fetch"].results["count"] == 0
      assert by_name["fetch"].results["emails"] == []
      assert by_name["fetch"].results["__cascade__"]["fetch"]["count"] == 0

      # conditional edges: notify path taken, draft path skipped
      assert by_name["fetch__to__notify__edge"].status == "completed"
      assert by_name["fetch__to__draft__edge"].status == "skipped"
      assert by_name["fetch__to__draft__edge"].results["field"] == "count"
      assert by_name["fetch__to__draft__edge"].results["op"] == "gt"
      assert by_name["fetch__to__draft__edge"].results["actual"] == "0"
      assert by_name["fetch__to__draft__edge"].results["expected"] == "0"

      # notify: ran, cascade extended
      assert by_name["notify"].status == "completed"
      assert by_name["notify"].results["notified"] == true
      assert by_name["notify"].results["status"] == "skipped"
      assert by_name["notify"].results["__cascade__"]["fetch"]["count"] == 0
      assert by_name["notify"].results["__cascade__"]["notify"]["notified"] == true

      # log_summary: 4 steps (fetch · 2 edge steps · notify), no failures
      log = run.log_summary
      assert log["step_count"] == 4
      assert log["failed_step_count"] == 0
      assert log["failed_steps"] == []

      lt = log_timeline(run)
      assert lt["fetch"]["status"] == "completed"
      assert lt["fetch__to__notify__edge"]["status"] == "completed"
      assert lt["fetch__to__draft__edge"]["status"] == "skipped"
      assert lt["notify"]["status"] == "completed"
      refute Map.has_key?(lt, "draft")
    end

    test "only fetch and notify steps run" do
      {workflow, _trigger} = setup_workflow(InboxEmpty, 0)

      :ok = fire()

      run = latest_run(workflow)
      by_name = step_runs(run)

      # only action steps that ran
      assert by_name["fetch"].status == "completed"
      assert by_name["notify"].status == "completed"
      refute Map.has_key?(by_name, "draft")
      refute Map.has_key?(by_name, "review_draft")

      # fetch result
      assert by_name["fetch"].results["count"] == 0
      assert by_name["fetch"].results["emails"] == []

      # notify cascade includes fetch data
      assert by_name["notify"].results["notified"] == true
      assert by_name["notify"].results["__cascade__"]["fetch"]["count"] == 0
      assert by_name["notify"].results["__cascade__"]["notify"]["notified"] == true

      # log_summary: 4 entries total (fetch · 2 edges · notify)
      lt = log_timeline(run)
      assert map_size(lt) == 4
      assert lt["fetch"]["status"] == "completed"
      assert lt["notify"]["status"] == "completed"
      refute Map.has_key?(lt, "draft")
      refute Map.has_key?(lt, "review_draft")
    end
  end

  # ---------------------------------------------------------------------------
  # Path 3: emails found, draft exceeds 200ms timeout
  # ---------------------------------------------------------------------------

  describe "emails found — draft times out (> 200ms)" do
    test "creates a run and marks it failed" do
      {workflow, _trigger} = setup_workflow(InboxWithResults, 250)

      assert :ok = fire()

      run = latest_run(workflow)
      assert run.status == "failed"

      by_name = step_runs(run)

      # fetch completed normally
      assert by_name["fetch"].status == "completed"
      assert by_name["fetch"].results["count"] == 1
      assert by_name["fetch"].results["emails"] == [@alice_email]

      # edge: draft path attempted
      assert by_name["fetch__to__draft__edge"].status == "completed"
      assert by_name["fetch__to__notify__edge"].status == "skipped"

      # draft: timed out
      assert by_name["draft"].status == "failed"
      assert by_name["draft"].errors["reason"] == "timeout"

      # log_summary: 4 steps, draft failure recorded
      log = run.log_summary
      assert log["step_count"] == 4
      assert log["failed_step_count"] == 1
      assert log["failed_steps"] == ["draft"]

      lt = log_timeline(run)
      assert lt["fetch"]["status"] == "completed"
      assert lt["draft"]["status"] == "failed"
    end

    test "fetch completes, draft is marked failed with reason 'timeout'" do
      {workflow, _trigger} = setup_workflow(InboxWithResults, 250)

      :ok = fire()

      run = latest_run(workflow)
      by_name = step_runs(run)

      # fetch: emails found, cascade intact
      assert by_name["fetch"].status == "completed"
      assert by_name["fetch"].results["count"] == 1
      assert by_name["fetch"].results["emails"] == [@alice_email]
      assert by_name["fetch"].results["__cascade__"]["fetch"]["count"] == 1

      # draft: timeout error stored
      assert by_name["draft"].status == "failed"
      assert by_name["draft"].errors["reason"] == "timeout"
      assert by_name["draft"].results == nil

      # log_summary: draft appears as failed
      lt = log_timeline(run)
      assert lt["fetch"]["status"] == "completed"
      assert lt["draft"]["status"] == "failed"
    end

    test "run is never left in 'running' state after timeout" do
      {workflow, _trigger} = setup_workflow(InboxWithResults, 250)

      :ok = fire()

      run = latest_run(workflow)
      refute run.status == "running"

      by_name = step_runs(run)

      # fetch still recorded its results before draft failed
      assert by_name["fetch"].results["count"] == 1
      assert by_name["draft"].errors["reason"] == "timeout"

      # log_summary: no step left in "running"
      lt = log_timeline(run)
      assert Enum.all?(lt, fn {_name, entry} -> entry["status"] != "running" end)
    end
  end

  # ---------------------------------------------------------------------------
  # Path 4: emails found, draft returns a hard error (< 200ms, no timeout)
  # ---------------------------------------------------------------------------

  describe "emails found — draft returns 500 error" do
    test "run fails immediately and draft error is recorded" do
      {workflow, _trigger} = setup_workflow(InboxWithResults, 0, DraftReplyErrorStub)

      assert :ok = fire()

      run = latest_run(workflow)
      assert run.status == "failed"

      by_name = step_runs(run)

      # fetch: completed normally, cascade seeded
      assert by_name["fetch"].status == "completed"
      assert by_name["fetch"].results["count"] == 1
      assert by_name["fetch"].results["emails"] == [@alice_email]
      assert by_name["fetch"].results["__cascade__"]["fetch"]["count"] == 1

      # edge routing: draft path attempted, notify path skipped
      assert by_name["fetch__to__draft__edge"].status == "completed"
      assert by_name["fetch__to__notify__edge"].status == "skipped"

      # draft: failed with the error reason, no results stored
      assert by_name["draft"].status == "failed"
      assert by_name["draft"].errors["reason"] == ":internal_server_error"
      assert by_name["draft"].results == nil

      # downstream steps never executed
      refute Map.has_key?(by_name, "review_draft")
      refute Map.has_key?(by_name, "ensure_person")
      refute Map.has_key?(by_name, "send_reply")

      # log_summary: 4 steps, 1 failure, no step left running
      log = run.log_summary
      assert log["step_count"] == 4
      assert log["failed_step_count"] == 1
      assert log["failed_steps"] == ["draft"]

      lt = log_timeline(run)
      assert lt["fetch"]["status"] == "completed"
      assert lt["fetch__to__draft__edge"]["status"] == "completed"
      assert lt["fetch__to__notify__edge"]["status"] == "skipped"
      assert lt["draft"]["status"] == "failed"
      refute Map.has_key?(lt, "review_draft")
    end

    test "fetch cascade intact when draft errors out" do
      {workflow, _trigger} = setup_workflow(InboxWithResults, 0, DraftReplyErrorStub)

      :ok = fire()

      run = latest_run(workflow)
      by_name = step_runs(run)

      # fetch stored its full cascade before draft failed
      assert by_name["fetch"].results["__cascade__"]["fetch"]["count"] == 1
      assert by_name["fetch"].results["__cascade__"]["fetch"]["emails"] == [@alice_email]

      # draft has no results — error only
      assert by_name["draft"].results == nil
      assert by_name["draft"].errors["reason"] == ":internal_server_error"

      # log_summary: no step stuck in "running"
      lt = log_timeline(run)
      assert Enum.all?(lt, fn {_name, entry} -> entry["status"] != "running" end)
    end
  end

  # ---------------------------------------------------------------------------
  # Path 5: emails found, HITL approved → full workflow completes
  # ---------------------------------------------------------------------------

  # Like setup_workflow/2 but uses HumanInTheLoop for review_draft so that
  # a StepApproval record is created in the DB when the step is reached.
  # The review_draft → ensure_person edge carries a mapping to restore `drafts`
  # from the cascade: after HITL approval the top-level fact is
  # %{approved: true, ...}, so `drafts` must be pulled via "draft.drafts".
  defp setup_workflow_with_hitl(fetch_module, draft_delay_ms) do
    nodes = [
      %{
        name: "fetch",
        type: "action",
        module: inspect(fetch_module),
        params: %{"mailbox" => "test"},
        index: 0
      },
      %{
        name: "draft",
        type: "action",
        module: inspect(DraftReplyStub),
        params: %{"delay_ms" => draft_delay_ms, "timeout_ms" => @draft_timeout_ms},
        index: 1
      },
      %{
        name: "notify",
        type: "action",
        module: inspect(EmptyInboxNotificationStub),
        params: %{"notify_address" => @notify_address},
        index: 1
      },
      %{
        name: "review_draft",
        type: "action",
        module: inspect(HumanInTheLoop),
        params: %{},
        index: 2
      },
      %{
        name: "ensure_person",
        type: "action",
        module: inspect(EnsurePersonStub),
        params: %{},
        index: 3
      },
      %{
        name: "send_reply",
        type: "action",
        module: inspect(SendReplyStub),
        params: %{},
        index: 4
      }
    ]

    edges = [
      %{from: "fetch", to: "draft", condition: %{"field" => "count", "op" => "gt", "value" => 0}},
      %{
        from: "fetch",
        to: "notify",
        condition: %{"field" => "count", "op" => "eq", "value" => 0}
      },
      %{from: "draft", to: "review_draft"},
      %{from: "review_draft", to: "ensure_person", mapping: %{"drafts" => "draft.drafts"}},
      %{from: "ensure_person", to: "send_reply"}
    ]

    {:ok, workflow} =
      Workflows.create_workflow(%{
        name: "Mail Responder HITL Test #{System.unique_integer()}",
        status: "active",
        nodes: nodes,
        edges: edges
      })

    {:ok, trigger} =
      Workflows.create_trigger(%{event_name: @event_name, enabled: true})

    {:ok, _} = Workflows.assign_workflow_to_trigger(trigger, workflow)

    {workflow, trigger}
  end

  describe "emails found — HITL approved" do
    test "run completes after approval" do
      {workflow, _trigger} = setup_workflow_with_hitl(InboxWithResults, 0)

      :ok = fire()

      run = latest_run(workflow)
      assert run.status == "waiting"

      # log_summary BEFORE approval: 5 steps, review_draft is "waiting"
      log_before = run.log_summary
      assert log_before["step_count"] == 5
      assert log_before["failed_step_count"] == 0
      lt_before = log_timeline(run)
      assert lt_before["fetch"]["status"] == "completed"
      assert lt_before["draft"]["status"] == "completed"
      assert lt_before["review_draft"]["status"] == "waiting"
      refute Map.has_key?(lt_before, "ensure_person")
      refute Map.has_key?(lt_before, "send_reply")

      approval = Workflows.get_pending_approval(run.id)
      assert approval != nil
      assert approval.step_name == "review_draft"

      assert {:ok, _} = Workflows.approve_step(run, approval, %{}, nil)

      # Reload from DB to get JSONB-decoded (string-keyed) log_summary
      completed_run = Workflows.get_run(run.id)
      assert completed_run.status == "completed"

      by_name = step_runs(run)

      # fetch
      assert by_name["fetch"].results["count"] == 1
      assert by_name["fetch"].results["emails"] == [@alice_email]

      # draft cascade
      assert by_name["draft"].results["drafts"] == [@alice_draft]
      assert by_name["draft"].results["__cascade__"]["fetch"]["count"] == 1

      # review_draft: completed via approval, prior cascade rebuilt
      assert by_name["review_draft"].results["approved"] == true
      assert by_name["review_draft"].results["approved_by"] == nil
      assert by_name["review_draft"].results["__cascade__"]["fetch"]["count"] == 1
      assert by_name["review_draft"].results["__cascade__"]["draft"]["drafts"] == [@alice_draft]

      # edge mapping injected drafts from cascade into ensure_person
      assert by_name["review_draft__to__ensure_person__edge"].status == "completed"

      # ensure_person: received drafts, enriched with person_id
      enriched = by_name["ensure_person"].results["drafts"]
      assert length(enriched) == 1
      assert hd(enriched)["to_address"] == "alice@example.com"
      assert hd(enriched)["person_id"] == "test-person-id"

      # send_reply: email dispatched
      assert by_name["send_reply"].results["sent"] == 1
      assert by_name["send_reply"].results["failed"] == 0
      sent = by_name["send_reply"].results["results"]
      assert length(sent) == 1
      assert hd(sent)["to"] == "alice@example.com"
      assert hd(sent)["status"] == "sent"

      # log_summary AFTER approval: 8 steps, all completed
      # (+ review_draft__to__ensure_person__edge · ensure_person · send_reply)
      log_after = completed_run.log_summary
      assert log_after["step_count"] == 8
      assert log_after["failed_step_count"] == 0
      lt_after = log_timeline(completed_run)
      assert lt_after["review_draft"]["status"] == "completed"
      assert lt_after["review_draft__to__ensure_person__edge"]["status"] == "completed"
      assert lt_after["ensure_person"]["status"] == "completed"
      assert lt_after["send_reply"]["status"] == "completed"
    end

    test "all five steps complete with full cascade after approval" do
      {workflow, _trigger} = setup_workflow_with_hitl(InboxWithResults, 0)

      :ok = fire()

      run = latest_run(workflow)

      # Before approval: 5 entries, review_draft waiting
      assert run.log_summary["step_count"] == 5
      lt_before = log_timeline(run)
      assert lt_before["review_draft"]["status"] == "waiting"

      approval = Workflows.get_pending_approval(run.id)
      {:ok, _} = Workflows.approve_step(run, approval, %{}, nil)

      # Reload from DB so log_summary has JSONB-decoded string keys
      completed_run = Workflows.get_run(run.id)

      by_name =
        run.id
        |> Workflows.list_step_runs()
        |> Map.new(&{&1.step_name, &1})

      # --- step statuses ---
      assert by_name["fetch"].status == "completed"
      assert by_name["draft"].status == "completed"
      assert by_name["review_draft"].status == "completed"
      assert by_name["ensure_person"].status == "completed"
      assert by_name["send_reply"].status == "completed"

      # --- edge routing ---
      assert by_name["fetch__to__draft__edge"].status == "completed"
      assert by_name["fetch__to__notify__edge"].status == "skipped"
      assert by_name["review_draft__to__ensure_person__edge"].status == "completed"

      # --- fetch results ---
      assert by_name["fetch"].results["count"] == 1
      assert by_name["fetch"].results["emails"] == [@alice_email]
      assert by_name["fetch"].results["__cascade__"]["fetch"]["count"] == 1

      # --- draft results ---
      assert by_name["draft"].results["drafts"] == [@alice_draft]
      assert by_name["draft"].results["__cascade__"]["fetch"]["count"] == 1
      assert by_name["draft"].results["__cascade__"]["draft"]["drafts"] == [@alice_draft]

      # --- review_draft approval + rebuilt cascade ---
      assert by_name["review_draft"].results["approved"] == true
      assert by_name["review_draft"].results["approved_by"] == nil
      assert by_name["review_draft"].results["decision"] == %{}
      assert by_name["review_draft"].results["__cascade__"]["fetch"]["count"] == 1
      assert by_name["review_draft"].results["__cascade__"]["draft"]["drafts"] == [@alice_draft]

      # --- ensure_person: drafts enriched with person_id ---
      enriched = by_name["ensure_person"].results["drafts"]
      assert length(enriched) == 1
      assert hd(enriched)["to_address"] == "alice@example.com"
      assert hd(enriched)["to_name"] == "Alice"
      assert hd(enriched)["person_id"] == "test-person-id"
      assert by_name["ensure_person"].results["__cascade__"]["fetch"]["count"] == 1

      # --- send_reply: email sent ---
      assert by_name["send_reply"].results["sent"] == 1
      assert by_name["send_reply"].results["failed"] == 0
      sent = by_name["send_reply"].results["results"]
      assert length(sent) == 1
      assert hd(sent)["to"] == "alice@example.com"
      assert hd(sent)["status"] == "sent"
      assert by_name["send_reply"].results["__cascade__"]["fetch"]["count"] == 1

      # log_summary AFTER approval: 8 entries, every step completed/skipped
      log_after = completed_run.log_summary
      assert log_after["step_count"] == 8
      assert log_after["failed_step_count"] == 0
      assert log_after["failed_steps"] == []

      lt_after = log_timeline(completed_run)
      assert lt_after["fetch"]["status"] == "completed"
      assert lt_after["fetch__to__draft__edge"]["status"] == "completed"
      assert lt_after["fetch__to__notify__edge"]["status"] == "skipped"
      assert lt_after["draft"]["status"] == "completed"
      assert lt_after["review_draft"]["status"] == "completed"
      assert lt_after["review_draft__to__ensure_person__edge"]["status"] == "completed"
      assert lt_after["ensure_person"]["status"] == "completed"
      assert lt_after["send_reply"]["status"] == "completed"
    end
  end
end
