defmodule Zaq.Engine.Workflows.CronTriggerWorkerTest do
  use Zaq.DataCase, async: false

  import Mox

  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.CronTriggerWorker

  setup :verify_on_exit!

  setup do
    stub(Zaq.NodeRouterMock, :find_node, fn _sup -> :services@localhost end)
    stub(Zaq.NodeRouterMock, :dispatch, fn event -> event end)
    :ok
  end

  defp build_job(trigger_id) do
    %Oban.Job{args: %{"trigger_id" => trigger_id}}
  end

  defp create_cron_trigger(attrs \\ %{}) do
    defaults = %{
      event_name: "cron.test_#{System.unique_integer([:positive])}",
      trigger_type: "cron",
      cron_schedule: "0 * * * *",
      enabled: true
    }

    {:ok, t} = Workflows.create_trigger(Map.merge(defaults, attrs))
    t
  end

  defp create_event_trigger(attrs \\ %{}) do
    defaults = %{
      event_name: "event.test_#{System.unique_integer([:positive])}",
      trigger_type: "event",
      enabled: true
    }

    {:ok, t} = Workflows.create_trigger(Map.merge(defaults, attrs))
    t
  end

  # ---------------------------------------------------------------------------
  # Happy path
  # ---------------------------------------------------------------------------

  describe "perform/1 — happy path" do
    test "dispatches a NodeRouter event for an enabled cron trigger" do
      trigger = create_cron_trigger()

      stub(Zaq.NodeRouterMock, :dispatch, fn event ->
        assert event.name == trigger.event_name
        assert event.next_hop.destination == :engine
        event
      end)

      assert :ok = CronTriggerWorker.perform(build_job(trigger.id))
    end
  end

  # ---------------------------------------------------------------------------
  # Safe discards
  # ---------------------------------------------------------------------------

  describe "perform/1 — safe discards" do
    test "returns :ok without dispatch when trigger is not found" do
      stub(Zaq.NodeRouterMock, :dispatch, fn _event ->
        flunk("dispatch should not be called for missing trigger")
      end)

      assert :ok = CronTriggerWorker.perform(build_job(Ecto.UUID.generate()))
    end

    test "returns :ok without dispatch when trigger is disabled" do
      trigger = create_cron_trigger(%{enabled: false})

      stub(Zaq.NodeRouterMock, :dispatch, fn _event ->
        flunk("dispatch should not be called for disabled trigger")
      end)

      assert :ok = CronTriggerWorker.perform(build_job(trigger.id))
    end

    test "returns :ok without dispatch when trigger_type is 'event'" do
      trigger = create_event_trigger()

      stub(Zaq.NodeRouterMock, :dispatch, fn _event ->
        flunk("dispatch should not be called for event trigger")
      end)

      assert :ok = CronTriggerWorker.perform(build_job(trigger.id))
    end
  end

  # ---------------------------------------------------------------------------
  # Event shape
  # ---------------------------------------------------------------------------

  describe "perform/1 — event shape" do
    test "dispatches event with the trigger's event_name as the name field" do
      trigger = create_cron_trigger(%{event_name: "cron.daily_sync"})

      dispatched_event = start_supervised!({Agent, fn -> nil end})

      stub(Zaq.NodeRouterMock, :dispatch, fn event ->
        Agent.update(dispatched_event, fn _ -> event end)
        event
      end)

      :ok = CronTriggerWorker.perform(build_job(trigger.id))

      event = Agent.get(dispatched_event, & &1)
      assert event.name == "engine:cron.daily_sync"
    end

    test "dispatches event routed to :engine destination" do
      trigger = create_cron_trigger()
      dispatched = start_supervised!({Agent, fn -> nil end})

      stub(Zaq.NodeRouterMock, :dispatch, fn event ->
        Agent.update(dispatched, fn _ -> event end)
        event
      end)

      :ok = CronTriggerWorker.perform(build_job(trigger.id))

      event = Agent.get(dispatched, & &1)
      assert event.next_hop.destination == :engine
    end
  end

  # ---------------------------------------------------------------------------
  # Burst firing — simulates the cron worker being enqueued N times in a row
  # ---------------------------------------------------------------------------

  describe "perform/1 — burst firing" do
    test "dispatches exactly 10 events when the worker fires 10 times over 100 ms" do
      trigger = create_cron_trigger(%{event_name: "cron.burst_test"})
      counter = start_supervised!({Agent, fn -> 0 end})

      stub(Zaq.NodeRouterMock, :dispatch, fn event ->
        assert event.name == trigger.event_name
        Agent.update(counter, &(&1 + 1))
        event
      end)

      job = build_job(trigger.id)

      for _ <- 1..10 do
        assert :ok = CronTriggerWorker.perform(job)
        Process.sleep(10)
      end

      assert Agent.get(counter, & &1) == 10
    end
  end
end
