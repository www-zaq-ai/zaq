defmodule Zaq.Engine.Workflows.LifecycleNotifierTest do
  @moduledoc """
  Unit tests for the lifecycle notification seam.

  Lifecycle notification is observational: the run has already been persisted
  by the time it fires, so a rejecting, raising, exiting or throwing subscriber
  must be contained and logged here rather than unwinding the caller. These
  tests drive the configured `:node_router` (the Mox `Zaq.NodeRouterMock`)
  directly, without a database run, so each failure mode is asserted in
  isolation from execution.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Mox

  alias Zaq.Engine.Workflows.LifecycleNotifier
  alias Zaq.Engine.Workflows.WorkflowRun
  alias Zaq.Event

  setup :verify_on_exit!

  setup do
    actor = %{type: :person, id: Ecto.UUID.generate()}

    run = %WorkflowRun{
      id: Ecto.UUID.generate(),
      workflow_id: Ecto.UUID.generate(),
      source_event: Event.new(%{}, :engine, name: :workflow, actor: actor)
    }

    %{run: run, actor: actor}
  end

  describe "notify/2" do
    test "dispatches a :workflow event carrying the action, run and source actor", %{
      run: run,
      actor: actor
    } do
      stub(Zaq.NodeRouterMock, :dispatch, fn event ->
        send(self(), {:dispatched, event})
        %{event | response: :ok}
      end)

      log =
        capture_log(fn ->
          assert %Event{response: :ok} = LifecycleNotifier.notify("run.completed", run)
        end)

      assert_received {:dispatched, %Event{} = event}
      assert event.name == :workflow
      assert event.next_hop.destination == :engine
      assert event.actor == actor

      assert event.request == %{
               action: "run.completed",
               run_id: run.id,
               workflow_id: run.workflow_id
             }

      refute log =~ "lifecycle notification failed"
    end

    test "dispatches with a nil actor when the run has no source event", %{run: run} do
      run = %{run | source_event: nil}

      stub(Zaq.NodeRouterMock, :dispatch, fn event ->
        send(self(), {:dispatched, event})
        event
      end)

      LifecycleNotifier.notify("run.started", run)

      assert_received {:dispatched, %Event{actor: nil}}
    end

    test "logs and still returns the event when a subscriber responds with an error", %{run: run} do
      stub(Zaq.NodeRouterMock, :dispatch, fn event ->
        %{event | response: {:error, :subscriber_rejected}}
      end)

      log =
        capture_log(fn ->
          assert %Event{response: {:error, :subscriber_rejected}} =
                   LifecycleNotifier.notify("run.failed", run)
        end)

      assert log =~ "lifecycle notification failed"
      assert log =~ "event_name=run.failed"
      assert log =~ "run_id=#{run.id}"
      assert log =~ "failure_kind=error"
      assert log =~ "reason=:subscriber_rejected"
    end

    test "logs and still returns a bare error tuple from the router", %{run: run} do
      stub(Zaq.NodeRouterMock, :dispatch, fn _event -> {:error, :no_node} end)

      log =
        capture_log(fn ->
          assert {:error, :no_node} = LifecycleNotifier.notify("run.incomplete", run)
        end)

      assert log =~ "lifecycle notification failed"
      assert log =~ "event_name=run.incomplete"
      assert log =~ "failure_kind=error"
      assert log =~ "reason=:no_node"
    end

    test "contains a raising subscriber and logs its message", %{run: run} do
      stub(Zaq.NodeRouterMock, :dispatch, fn _event -> raise "subscriber blew up" end)

      log = capture_log(fn -> assert :ok = LifecycleNotifier.notify("run.waiting", run) end)

      assert log =~ "lifecycle notification failed"
      assert log =~ "event_name=run.waiting"
      assert log =~ "failure_kind=error"
      assert log =~ "reason=subscriber blew up"
    end

    test "contains an exiting subscriber", %{run: run} do
      stub(Zaq.NodeRouterMock, :dispatch, fn _event -> exit(:router_down) end)

      log = capture_log(fn -> assert :ok = LifecycleNotifier.notify("run.started", run) end)

      assert log =~ "lifecycle notification failed"
      assert log =~ "failure_kind=exit"
      assert log =~ "reason=:router_down"
    end

    test "contains a throwing subscriber", %{run: run} do
      stub(Zaq.NodeRouterMock, :dispatch, fn _event -> throw(:nope) end)

      log = capture_log(fn -> assert :ok = LifecycleNotifier.notify("run.completed", run) end)

      assert log =~ "lifecycle notification failed"
      assert log =~ "failure_kind=throw"
      assert log =~ "reason=:nope"
    end
  end
end
