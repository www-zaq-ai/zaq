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

  defp create_trigger(type, config \\ %{}) do
    {:ok, t} = Workflows.create_trigger(%{type: type, config: config})
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

  describe "Manual.fire/2" do
    test "returns an event with trigger_type :manual" do
      trigger = create_trigger("manual")
      input = %{user_id: "u1", note: "test run"}

      assert {:ok, event} = Manual.fire(trigger, input)
      assert event.assigns.trigger_type == :manual
      assert event.assigns.input == input
    end

    test "event carries a trace_id" do
      trigger = create_trigger("manual")
      {:ok, event} = Manual.fire(trigger, %{})
      assert is_binary(event.trace_id)
    end
  end

  # --- Manual.fire_for_workflow/2 ---

  describe "Manual.fire_for_workflow/2" do
    test "creates a WorkflowRun with pending status" do
      workflow = create_workflow()
      input = %{user_id: "u1"}

      assert {:ok, %WorkflowRun{} = run} = Manual.fire_for_workflow(workflow, input)
      assert run.workflow_id == workflow.id
      assert run.status == "pending"
    end

    test "snapshots steps from the workflow" do
      workflow = create_workflow()
      {:ok, run} = Manual.fire_for_workflow(workflow, %{})
      assert run.steps_snapshot["nodes"] != nil
    end

    test "source_event has trigger_type :manual" do
      workflow = create_workflow()
      {:ok, run} = Manual.fire_for_workflow(workflow, %{mailbox: "INBOX"})
      assert run.source_event.assigns.trigger_type == :manual
    end
  end

  # --- Webhook trigger ---

  describe "Webhook.fire/2" do
    test "returns an event with trigger_type :webhook and input" do
      trigger = create_trigger("webhook")
      payload = %{"event" => "user.created", "data" => %{"id" => "u1"}}

      assert {:ok, event} = Webhook.fire(trigger, payload)
      assert event.assigns.trigger_type == :webhook
      assert event.assigns.input == payload
    end
  end

  # --- Signal trigger ---

  describe "Signal.fire/2" do
    test "returns an event with trigger_type :signal and input" do
      trigger = create_trigger("signal", %{"topic" => "email.received"})
      payload = %{"from" => "test@example.com"}

      assert {:ok, event} = Signal.fire(trigger, payload)
      assert event.assigns.trigger_type == :signal
      assert event.assigns.input == payload
    end
  end

  # --- Scheduler trigger ---

  describe "Scheduler.fire/2" do
    test "returns an event with trigger_type :scheduler" do
      trigger = create_trigger("scheduler", %{"cron" => "0 * * * *"})
      {:ok, event} = Scheduler.fire(trigger, %{})
      assert event.assigns.trigger_type == :scheduler
    end

    test "nil trigger config defaults to empty static_input" do
      trigger = create_trigger("scheduler", %{"cron" => "0 * * * *"})
      trigger = %{trigger | config: nil}
      {:ok, event} = Scheduler.fire(trigger, %{})
      assert event.assigns.input == %{}
    end

    test "dynamic input is merged over static_input (dynamic wins on conflict)" do
      trigger =
        create_trigger("scheduler", %{
          "cron" => "0 * * * *",
          "static_input" => %{"mailbox" => "INBOX", "limit" => 10}
        })

      {:ok, event} = Scheduler.fire(trigger, %{"limit" => 99})
      assert event.assigns.input == %{"mailbox" => "INBOX", "limit" => 99}
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
