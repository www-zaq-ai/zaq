defmodule Zaq.Engine.Workflows.TriggerBehaviourTest do
  use Zaq.DataCase, async: true

  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.{Trigger, WorkflowRun}
  alias Zaq.Engine.Workflows.Triggers.{Manual, Scheduler, Signal, Webhook}

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

  defp create_trigger(workflow, type, config \\ %{}) do
    {:ok, t} = Workflows.create_trigger(%{workflow_id: workflow.id, type: type, config: config})
    t
  end

  # --- Trigger.module/1 ---

  describe "Trigger.module/1" do
    test "maps manual to Manual module" do
      assert {:ok, Manual} = Trigger.module(%Trigger{type: "manual"})
    end

    test "maps webhook to Webhook module" do
      assert {:ok, Webhook} = Trigger.module(%Trigger{type: "webhook"})
    end

    test "maps scheduler to Scheduler module" do
      assert {:ok, Scheduler} = Trigger.module(%Trigger{type: "scheduler"})
    end

    test "maps signal to Signal module" do
      assert {:ok, Signal} = Trigger.module(%Trigger{type: "signal"})
    end

    test "returns error for unknown type" do
      assert {:error, :unknown_type} = Trigger.module(%Trigger{type: "unknown"})
    end
  end

  # --- Manual trigger ---

  describe "Manual.fire/3" do
    test "creates a WorkflowRun with pending status" do
      workflow = create_workflow()
      trigger = create_trigger(workflow, "manual")
      input = %{user_id: "u1", note: "test run"}

      assert {:ok, %WorkflowRun{} = run} = Manual.fire(trigger, workflow, input)
      assert run.workflow_id == workflow.id
      assert run.status == "pending"
    end

    test "snapshots steps from the workflow" do
      workflow = create_workflow()
      trigger = create_trigger(workflow, "manual")

      {:ok, run} = Manual.fire(trigger, workflow, %{})
      assert run.steps_snapshot["nodes"] != nil
      assert run.steps_snapshot["edges"] != nil
    end

    test "source_event has trigger_type :manual in assigns" do
      workflow = create_workflow()
      trigger = create_trigger(workflow, "manual")

      {:ok, run} = Manual.fire(trigger, workflow, %{input: "data"})
      assert run.source_event.assigns.trigger_type == :manual
    end

    test "source_event carries a trace_id" do
      workflow = create_workflow()
      trigger = create_trigger(workflow, "manual")

      {:ok, run} = Manual.fire(trigger, workflow, %{})
      assert is_binary(run.source_event.trace_id)
    end

    test "source_event carries the input in assigns" do
      workflow = create_workflow()
      trigger = create_trigger(workflow, "manual")
      input = %{mailbox: "INBOX"}

      {:ok, run} = Manual.fire(trigger, workflow, input)
      assert run.source_event.assigns.input == input
    end
  end

  # --- Scheduler trigger ---

  describe "Scheduler.fire/3" do
    test "creates a WorkflowRun with pending status" do
      workflow = create_workflow()

      trigger =
        create_trigger(workflow, "scheduler", %{
          "cron" => "*/30 * * * *",
          "static_input" => %{"mailbox" => "INBOX"}
        })

      assert {:ok, %WorkflowRun{} = run} = Scheduler.fire(trigger, workflow, %{})
      assert run.status == "pending"
    end

    test "merges static_input from trigger config into assigns" do
      workflow = create_workflow()

      trigger =
        create_trigger(workflow, "scheduler", %{
          "cron" => "*/5 * * * *",
          "static_input" => %{"mailbox" => "INBOX"}
        })

      {:ok, run} = Scheduler.fire(trigger, workflow, %{})
      assert run.source_event.assigns.input == %{"mailbox" => "INBOX"}
    end

    test "source_event has trigger_type :scheduler in assigns" do
      workflow = create_workflow()
      trigger = create_trigger(workflow, "scheduler", %{"cron" => "0 * * * *"})

      {:ok, run} = Scheduler.fire(trigger, workflow, %{})
      assert run.source_event.assigns.trigger_type == :scheduler
    end
  end

  # --- Webhook trigger ---

  describe "Webhook.fire/3" do
    test "creates a WorkflowRun carrying the webhook payload" do
      workflow = create_workflow()
      trigger = create_trigger(workflow, "webhook")
      payload = %{"event" => "user.created", "data" => %{"id" => "u1"}}

      assert {:ok, %WorkflowRun{} = run} = Webhook.fire(trigger, workflow, payload)
      assert run.source_event.assigns.trigger_type == :webhook
      assert run.source_event.assigns.input == payload
    end
  end

  # --- Signal trigger ---

  describe "Signal.fire/3" do
    test "creates a WorkflowRun carrying the signal payload" do
      workflow = create_workflow()
      trigger = create_trigger(workflow, "signal", %{"topic" => "email.received"})
      payload = %{"from" => "test@example.com"}

      assert {:ok, %WorkflowRun{} = run} = Signal.fire(trigger, workflow, payload)
      assert run.source_event.assigns.trigger_type == :signal
      assert run.source_event.assigns.input == payload
    end
  end

  # --- Scheduler edge cases ---

  describe "Scheduler.fire/3 — edge cases" do
    test "nil trigger config defaults to empty static_input" do
      workflow = create_workflow()
      trigger = create_trigger(workflow, "scheduler", %{"cron" => "0 * * * *"})
      trigger = %{trigger | config: nil}

      assert {:ok, %WorkflowRun{} = run} = Scheduler.fire(trigger, workflow, %{})
      assert run.source_event.assigns.input == %{}
    end

    test "dynamic input is merged over static_input (dynamic wins on conflict)" do
      workflow = create_workflow()

      trigger =
        create_trigger(workflow, "scheduler", %{
          "cron" => "0 * * * *",
          "static_input" => %{"mailbox" => "INBOX", "limit" => 10}
        })

      {:ok, run} = Scheduler.fire(trigger, workflow, %{"limit" => 99})
      assert run.source_event.assigns.input == %{"mailbox" => "INBOX", "limit" => 99}
    end
  end

  # --- on_complete callbacks ---

  describe "on_complete/2" do
    test "Manual.on_complete returns :ok" do
      assert :ok = Manual.on_complete(%{}, [])
    end

    test "Scheduler.on_complete returns :ok" do
      assert :ok = Scheduler.on_complete(%{}, [])
    end

    test "Webhook.on_complete returns :ok" do
      assert :ok = Webhook.on_complete(%{}, [])
    end

    test "Signal.on_complete returns :ok" do
      assert :ok = Signal.on_complete(%{}, [])
    end
  end
end
