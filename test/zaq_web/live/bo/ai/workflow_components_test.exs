defmodule ZaqWeb.Live.BO.AI.WorkflowComponentsTest do
  use ZaqWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ZaqWeb.Live.BO.AI.WorkflowComponents

  # ---------------------------------------------------------------------------
  # workflow_status_badge/1
  # ---------------------------------------------------------------------------

  describe "workflow_status_badge/1" do
    test "renders 'active' with emerald CSS class" do
      html = render_component(&WorkflowComponents.workflow_status_badge/1, status: "active")
      assert html =~ "active"
      assert html =~ "emerald"
    end

    test "renders 'archived' with muted CSS class" do
      html = render_component(&WorkflowComponents.workflow_status_badge/1, status: "archived")
      assert html =~ "archived"
      assert html =~ "bg-black/5"
    end

    test "renders draft status with amber CSS class (default)" do
      html = render_component(&WorkflowComponents.workflow_status_badge/1, status: "draft")
      assert html =~ "draft"
      assert html =~ "amber"
    end

    test "unknown status falls back to amber CSS class" do
      html = render_component(&WorkflowComponents.workflow_status_badge/1, status: "unknown")
      assert html =~ "unknown"
      assert html =~ "amber"
    end
  end

  # ---------------------------------------------------------------------------
  # run_status_badge/1
  # ---------------------------------------------------------------------------

  describe "run_status_badge/1" do
    test "renders 'completed' with emerald CSS class" do
      html = render_component(&WorkflowComponents.run_status_badge/1, status: "completed")
      assert html =~ "completed"
      assert html =~ "emerald"
    end

    test "renders 'failed' with red CSS class" do
      html = render_component(&WorkflowComponents.run_status_badge/1, status: "failed")
      assert html =~ "failed"
      assert html =~ "red"
    end

    test "renders 'running' with blue CSS class" do
      html = render_component(&WorkflowComponents.run_status_badge/1, status: "running")
      assert html =~ "running"
      assert html =~ "blue"
    end

    test "renders unknown status with muted CSS class (default)" do
      html = render_component(&WorkflowComponents.run_status_badge/1, status: "pending")
      assert html =~ "pending"
      assert html =~ "bg-black/5"
    end
  end

  # ---------------------------------------------------------------------------
  # run_duration/1
  # ---------------------------------------------------------------------------

  describe "run_duration/1" do
    test "renders em-dash when started_at is nil" do
      run = %{started_at: nil, finished_at: nil}
      html = render_component(&WorkflowComponents.run_duration/1, run: run)
      assert html =~ "—"
    end

    test "renders elapsed time with trailing '…' when finished_at is nil" do
      run = %{started_at: DateTime.add(DateTime.utc_now(), -10, :second), finished_at: nil}
      html = render_component(&WorkflowComponents.run_duration/1, run: run)
      assert html =~ "…"
      assert html =~ "s"
    end

    test "renders formatted duration when both started_at and finished_at are present" do
      started = ~U[2024-01-01 10:00:00Z]
      finished = ~U[2024-01-01 10:00:45Z]
      run = %{started_at: started, finished_at: finished}
      html = render_component(&WorkflowComponents.run_duration/1, run: run)
      assert html =~ "45s"
      refute html =~ "…"
    end

    test "formats durations >= 60s as minutes and seconds" do
      started = ~U[2024-01-01 10:00:00Z]
      finished = ~U[2024-01-01 10:02:30Z]
      run = %{started_at: started, finished_at: finished}
      html = render_component(&WorkflowComponents.run_duration/1, run: run)
      assert html =~ "2m"
      assert html =~ "30s"
    end
  end

  # ---------------------------------------------------------------------------
  # trigger_icon/1
  # ---------------------------------------------------------------------------

  describe "trigger_icon/1" do
    test "renders a phx-click button for enabled manual trigger" do
      trigger = %{type: "manual", enabled: true}

      html =
        render_component(&WorkflowComponents.trigger_icon/1,
          trigger: trigger,
          workflow_id: "wf-123"
        )

      assert html =~ ~s(phx-click="run_workflow")
      assert html =~ ~s(phx-value-workflow_id="wf-123")
      assert html =~ "<button"
    end

    test "does not render a button for disabled manual trigger" do
      trigger = %{type: "manual", enabled: false}

      html =
        render_component(&WorkflowComponents.trigger_icon/1,
          trigger: trigger,
          workflow_id: "wf-123"
        )

      refute html =~ ~s(phx-click="run_workflow")
      assert html =~ "<span"
    end

    test "renders icon (no button) for webhook trigger" do
      trigger = %{type: "webhook", enabled: true}

      html =
        render_component(&WorkflowComponents.trigger_icon/1,
          trigger: trigger,
          workflow_id: "wf-123"
        )

      refute html =~ ~s(phx-click="run_workflow")
      assert html =~ "<svg"
    end

    test "renders icon (no button) for scheduler trigger" do
      trigger = %{type: "scheduler", enabled: true}

      html =
        render_component(&WorkflowComponents.trigger_icon/1,
          trigger: trigger,
          workflow_id: "wf-123"
        )

      refute html =~ ~s(phx-click="run_workflow")
      assert html =~ "<svg"
    end
  end

  # ---------------------------------------------------------------------------
  # workflow_dag/1
  # ---------------------------------------------------------------------------

  describe "workflow_dag/1" do
    @node %{name: "fetch", type: "action", module: "SomeMod", params: %{}, index: 0}
    @node2 %{name: "send", type: "action", module: "SomeMod2", params: %{}, index: 1}
    @edge %{from: "fetch", to: "send"}

    test "renders 'No steps defined.' when nodes is empty" do
      html = render_component(&WorkflowComponents.workflow_dag/1, nodes: [], edges: [])
      assert html =~ "No steps defined."
      refute html =~ "<svg"
    end

    test "renders an SVG element when nodes is non-empty" do
      html = render_component(&WorkflowComponents.workflow_dag/1, nodes: [@node], edges: [])
      assert html =~ "<svg"
      refute html =~ "No steps defined."
    end

    test "renders each node's name as text in the SVG" do
      html =
        render_component(&WorkflowComponents.workflow_dag/1,
          nodes: [@node, @node2],
          edges: [@edge]
        )

      assert html =~ "fetch"
      assert html =~ "send"
    end

    test "renders edges as path elements" do
      html =
        render_component(&WorkflowComponents.workflow_dag/1,
          nodes: [@node, @node2],
          edges: [@edge]
        )

      assert html =~ "<path"
    end

    test "nodes get green fill (#f0fdf4) when matching step_run has status 'completed'" do
      step_runs = [%{step_name: "fetch", status: "completed", id: "sr-1", step_index: 0}]

      html =
        render_component(&WorkflowComponents.workflow_dag/1,
          nodes: [@node],
          edges: [],
          step_runs: step_runs
        )

      assert html =~ "#f0fdf4"
    end

    test "nodes get red fill (#fef2f2) when matching step_run has status 'failed'" do
      step_runs = [%{step_name: "fetch", status: "failed", id: "sr-1", step_index: 0}]

      html =
        render_component(&WorkflowComponents.workflow_dag/1,
          nodes: [@node],
          edges: [],
          step_runs: step_runs
        )

      assert html =~ "#fef2f2"
    end

    test "nodes get default fill (#f4f4f5) when no step_runs passed" do
      html = render_component(&WorkflowComponents.workflow_dag/1, nodes: [@node], edges: [])
      assert html =~ "#f4f4f5"
    end

    test "accepts string-key map nodes (from steps_snapshot)" do
      node = %{
        "name" => "fetch",
        "type" => "action",
        "module" => "SomeMod",
        "params" => %{},
        "index" => 0
      }

      html = render_component(&WorkflowComponents.workflow_dag/1, nodes: [node], edges: [])
      assert html =~ "<svg"
      assert html =~ "fetch"
    end
  end
end
