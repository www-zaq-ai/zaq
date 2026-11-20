defmodule ZaqWeb.Live.BO.AI.WorkflowRunLiveSnapshotTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Phoenix.LiveView.Socket
  alias Zaq.Engine.Workflows.Step.Run, as: StepRun
  alias ZaqWeb.Live.BO.AI.WorkflowRunLive

  for status <- ~w(completed failed) do
    test "delayed waiting preserves #{status} approval fields and enriches trace evidence" do
      waiting = waiting_step()
      settled = settled_step(waiting, unquote(status))
      late_trace = %{"id" => "late", "kind" => "tool_started"}
      delayed = %{waiting | trace_events: [late_trace]}

      socket = socket_with([waiting])
      {:noreply, socket} = WorkflowRunLive.handle_info({:step_updated, settled}, socket)
      {:noreply, socket} = WorkflowRunLive.handle_info({:step_updated, delayed}, socket)

      expected = %{settled | trace_events: settled.trace_events ++ [late_trace]}
      assert socket.assigns.step_runs == [expected]
      assert socket.assigns.selected_step == "manual-selection"

      {:noreply, replayed} = WorkflowRunLive.handle_info({:step_updated, delayed}, socket)
      assert replayed.assigns.step_runs == [expected]
    end

    test "waiting accepts a legitimate #{status} approval snapshot" do
      waiting = waiting_step()
      settled = settled_step(waiting, unquote(status))

      {:noreply, socket} =
        WorkflowRunLive.handle_info({:step_updated, settled}, socket_with([waiting]))

      assert socket.assigns.step_runs == [settled]
    end
  end

  test "cancellation survives delayed waiting and paused snapshots" do
    waiting = waiting_step()
    cancelled = %{waiting | status: "cancelled"}

    for stale <- [waiting, %{waiting | status: "paused"}] do
      {:noreply, socket} =
        WorkflowRunLive.handle_info({:step_updated, stale}, socket_with([cancelled]))

      assert socket.assigns.step_runs == [cancelled]
    end
  end

  test "a distinct running row on resume is accepted alongside the settled row" do
    settled = settled_step(waiting_step(), "completed")
    resumed = %{waiting_step() | id: "resumed-step", status: "running", step_index: 1}

    {:noreply, socket} =
      WorkflowRunLive.handle_info({:step_updated, resumed}, socket_with([settled]))

    assert socket.assigns.step_runs == [settled, resumed]
    assert socket.assigns.selected_step == resumed.step_name
  end

  test "waiting still protects its lifecycle from delayed running snapshots" do
    waiting = waiting_step()
    delayed = %{waiting | status: "running", logs: [], trace_events: nil}

    {:noreply, socket} =
      WorkflowRunLive.handle_info({:step_updated, delayed}, socket_with([waiting]))

    assert socket.assigns.step_runs == [waiting]
    assert socket.assigns.selected_step == "manual-selection"
  end

  property "settled lifecycle fields survive reordered and repeated active snapshots" do
    check all(
            status <- member_of(~w(completed failed failed_fatal skipped)),
            stale_statuses <-
              list_of(member_of(~w(running waiting paused)), min_length: 1, max_length: 10),
            max_runs: 40
          ) do
      waiting = waiting_step()
      settled = settled_step(waiting, status)

      socket =
        Enum.reduce(stale_statuses, socket_with([settled]), fn stale_status, socket ->
          delayed = %{waiting | status: stale_status, trace_events: nil}
          {:noreply, socket} = WorkflowRunLive.handle_info({:step_updated, delayed}, socket)
          assert socket.assigns.step_runs == [settled]
          assert socket.assigns.selected_step == "manual-selection"
          socket
        end)

      assert socket.assigns.step_runs == [settled]
    end
  end

  defp socket_with(step_runs) do
    %Socket{
      assigns: %{
        __changed__: %{},
        step_runs: step_runs,
        selected_step: "manual-selection"
      }
    }
  end

  defp waiting_step do
    %StepRun{
      id: "approval-step",
      step_name: "review",
      step_index: 0,
      status: "waiting",
      results: nil,
      errors: nil,
      logs: [%{"level" => "info", "message" => "Waiting for review"}],
      started_at: ~U[2026-11-13 12:00:00Z],
      finished_at: nil,
      updated_at: ~U[2026-11-13 12:00:00Z],
      trace_events: []
    }
  end

  defp settled_step(waiting, status) do
    %{
      waiting
      | status: status,
        results: %{"approved" => status == "completed"},
        errors: if(status == "failed", do: %{"rejected" => true, "reason" => "Rejected via BO"}),
        logs: [%{"level" => "info", "message" => "Review settled"}],
        finished_at: ~U[2026-11-13 12:00:00Z],
        trace_events: [%{"id" => "settled", "kind" => "tool_completed"}]
    }
  end
end
