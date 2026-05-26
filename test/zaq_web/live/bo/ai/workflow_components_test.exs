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

    test "renders elapsed time with trailing '…' when finished_at is nil and run is active" do
      run = %{
        started_at: DateTime.add(DateTime.utc_now(), -10, :second),
        finished_at: nil,
        status: "running"
      }

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
      trigger = %{event_name: "manual_trigger", enabled: true}

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
      trigger = %{event_name: "manual_trigger", enabled: false}

      html =
        render_component(&WorkflowComponents.trigger_icon/1,
          trigger: trigger,
          workflow_id: "wf-123"
        )

      refute html =~ ~s(phx-click="run_workflow")
      assert html =~ "<span"
    end

    test "renders icon (no button) for webhook trigger" do
      trigger = %{event_name: "webhook_received", enabled: true}

      html =
        render_component(&WorkflowComponents.trigger_icon/1,
          trigger: trigger,
          workflow_id: "wf-123"
        )

      refute html =~ ~s(phx-click="run_workflow")
      assert html =~ "<svg"
    end

    test "renders icon (no button) for scheduler trigger" do
      trigger = %{event_name: "schedule_run", enabled: true}

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

    test "HITL node without a matching step_run gets amber fill (#fffbeb)" do
      node = %{
        name: "review",
        type: "action",
        module: "Zaq.Engine.Workflows.Steps.HumanInTheLoop",
        params: %{},
        index: 0
      }

      html =
        render_component(&WorkflowComponents.workflow_dag/1,
          nodes: [node],
          edges: [],
          step_runs: []
        )

      assert html =~ "#fffbeb"
    end

    test "node gets amber fill when string-key step_run has status 'waiting'" do
      node = %{name: "fetch", type: "action", module: "SomeMod", params: %{}, index: 0}

      step_runs = [
        %{"step_name" => "fetch", "status" => "waiting", "id" => "sr-1", "step_index" => 0}
      ]

      html =
        render_component(&WorkflowComponents.workflow_dag/1,
          nodes: [node],
          edges: [],
          step_runs: step_runs
        )

      assert html =~ "#fffbeb"
    end

    test "node gets pending fill (#f9fafb) when step_run status is 'pending'" do
      step_runs = [%{step_name: "fetch", status: "pending", id: "sr-1", step_index: 0}]

      html =
        render_component(&WorkflowComponents.workflow_dag/1,
          nodes: [@node],
          edges: [],
          step_runs: step_runs
        )

      assert html =~ "#f9fafb"
    end

    test "node gets default fill when step_run has an unknown status" do
      step_runs = [%{step_name: "fetch", status: "unknown_xyz", id: "sr-1", step_index: 0}]

      html =
        render_component(&WorkflowComponents.workflow_dag/1,
          nodes: [@node],
          edges: [],
          step_runs: step_runs
        )

      assert html =~ "#f4f4f5"
    end

    test "node gets correct fill when string-key step_run has non-waiting status" do
      step_runs = [
        %{"step_name" => "fetch", "status" => "completed", "id" => "sr-1", "step_index" => 0}
      ]

      html =
        render_component(&WorkflowComponents.workflow_dag/1,
          nodes: [@node],
          edges: [],
          step_runs: step_runs
        )

      assert html =~ "#f0fdf4"
    end

    test "renders without crashing when an edge references a missing target node" do
      edge = %{from: "fetch", to: "missing_node"}

      html =
        render_component(&WorkflowComponents.workflow_dag/1,
          nodes: [@node],
          edges: [edge]
        )

      assert html =~ "<svg"
    end

    test "renders without crashing when an edge references a missing source node" do
      edge = %{from: "missing_from", to: "fetch"}

      html =
        render_component(&WorkflowComponents.workflow_dag/1,
          nodes: [@node],
          edges: [edge]
        )

      assert html =~ "<svg"
    end

    test "HITL node module nil does not set amber fill" do
      node = %{name: "a", type: "action", module: nil, params: %{}, index: 0}
      html = render_component(&WorkflowComponents.workflow_dag/1, nodes: [node], edges: [])
      refute html =~ "#fffbeb"
    end

    test "non-binary module value does not set amber fill" do
      node = %{name: "a", type: "action", module: 123, params: %{}, index: 0}
      html = render_component(&WorkflowComponents.workflow_dag/1, nodes: [node], edges: [])
      refute html =~ "#fffbeb"
    end

    test "batch node with post_process and nested iterate renders inner section and post label" do
      node = %{
        name: "batch",
        type: "action",
        module: "Zaq.Agent.Tools.Workflow.Batch",
        index: 0,
        params: %{
          "process" => [
            %{"name" => "plain_step", "module" => "SomeMod"},
            %{
              "name" => "iter_step",
              "module" => "Zaq.Agent.Tools.Workflow.Iterate",
              "params" => %{"pipeline" => [%{"name" => "inner_1"}, %{"name" => "inner_2"}]}
            }
          ],
          "post_process" => [%{"name" => "post_1", "module" => "SomePost"}]
        }
      }

      html = render_component(&WorkflowComponents.workflow_dag/1, nodes: [node], edges: [])
      assert html =~ "POST PROCESS"
      assert html =~ "inner_1"
      assert html =~ "inner_2"
      assert html =~ "marker-end=\"url(#dag-arr)\""
    end

    test "standalone iterate node renders stacked mini nodes with arrows" do
      node = %{
        name: "iter",
        type: "action",
        module: "Zaq.Agent.Tools.Workflow.Iterate",
        index: 0,
        params: %{"pipeline" => [%{"name" => "a"}, %{"name" => "b"}, %{"name" => "c"}]}
      }

      html = render_component(&WorkflowComponents.workflow_dag/1, nodes: [node], edges: [])
      assert html =~ "a"
      assert html =~ "b"
      assert html =~ "c"
      assert html =~ "marker-end=\"url(#dag-arr)\""
    end
  end

  # ---------------------------------------------------------------------------
  # trigger_type_icon/1 — additional variants
  # ---------------------------------------------------------------------------

  describe "trigger_type_icon/1 — all types" do
    test "renders signal icon for signal trigger" do
      trigger = %{event_name: "signal_received", enabled: true}

      html =
        render_component(&WorkflowComponents.trigger_icon/1,
          trigger: trigger,
          workflow_id: "wf-1"
        )

      assert html =~ "<svg"
      refute html =~ ~s(phx-click="run_workflow")
    end

    test "renders fallback icon for unknown trigger type" do
      trigger = %{event_name: "custom_event", enabled: true}

      html =
        render_component(&WorkflowComponents.trigger_icon/1,
          trigger: trigger,
          workflow_id: "wf-1"
        )

      assert html =~ "<svg"
      refute html =~ ~s(phx-click="run_workflow")
    end

    test "trigger_display_type falls back to 'event' for nil event_name" do
      trigger = %{event_name: nil, enabled: false}

      html =
        render_component(&WorkflowComponents.trigger_icon/1,
          trigger: trigger,
          workflow_id: "wf-1"
        )

      assert html =~ "<span"
    end
  end

  # ---------------------------------------------------------------------------
  # run_status_badge/1 — missing statuses
  # ---------------------------------------------------------------------------

  describe "run_status_badge/1 — additional statuses" do
    test "renders 'waiting' with amber CSS class" do
      html = render_component(&WorkflowComponents.run_status_badge/1, status: "waiting")
      assert html =~ "waiting"
      assert html =~ "amber"
    end

    test "renders 'cancelled' with orange CSS class" do
      html = render_component(&WorkflowComponents.run_status_badge/1, status: "cancelled")
      assert html =~ "cancelled"
      assert html =~ "orange"
    end

    test "renders 'paused' with muted CSS class" do
      html = render_component(&WorkflowComponents.run_status_badge/1, status: "paused")
      assert html =~ "paused"
      assert html =~ "bg-black/5"
    end
  end

  # ---------------------------------------------------------------------------
  # step_log_entry/1
  # ---------------------------------------------------------------------------

  describe "step_log_entry/1" do
    test "renders step_failed event with red CSS class" do
      log = %{"event" => "step_failed", "reason" => "Something failed", "duration_ms" => 42}
      html = render_component(&WorkflowComponents.step_log_entry/1, log: log)
      assert html =~ "step_failed"
      assert html =~ "Something failed"
      assert html =~ "red"
    end

    test "renders chunk_error event with red CSS class" do
      log = %{"event" => "chunk_error", "errors" => "Warning occurred", "duration_ms" => 42}
      html = render_component(&WorkflowComponents.step_log_entry/1, log: log)
      assert html =~ "Warning occurred"
      assert html =~ "red"
    end

    test "renders step_completed event with default (black) CSS class" do
      log = %{"event" => "step_completed", "results" => "All good", "duration_ms" => 42}
      html = render_component(&WorkflowComponents.step_log_entry/1, log: log)
      assert html =~ "All good"
      refute html =~ "red"
    end

    test "renders without duration when duration_ms is absent" do
      log = %{"event" => "step_completed", "reason" => "No ts"}
      html = render_component(&WorkflowComponents.step_log_entry/1, log: log)
      assert html =~ "No ts"
      refute html =~ ~r/\d+ms/
    end
  end

  describe "batch_step_card/1 and iterate_step_card/1" do
    test "batch_step_card renders running live chunk progress counters" do
      step = %{
        id: "sr-b1",
        step_name: "batch_step",
        step_index: 0,
        status: "running",
        logs: [],
        results: %{},
        input: %{},
        errors: nil,
        started_at: DateTime.utc_now(),
        finished_at: nil
      }

      html =
        render_component(&WorkflowComponents.batch_step_card/1,
          step: step,
          batch_progress: %{
            current_chunk: 2,
            total_chunks: 5,
            successful_chunks: 1,
            failed_chunks: 1
          },
          iterate_progress: nil,
          node_params: %{"process" => [%{"name" => "p1"}]}
        )

      assert html =~ "2 / 5"
      assert html =~ "Chunks"
    end

    test "batch_step_card renders completed chunk results summary" do
      step = %{
        id: "sr-b2",
        step_name: "batch_done",
        step_index: 0,
        status: "completed",
        logs: [],
        input: %{},
        errors: nil,
        started_at: ~U[2024-01-01 00:00:00Z],
        finished_at: ~U[2024-01-01 00:00:02Z],
        results: %{
          "results" => [
            %{"results" => [%{"id" => 1}], "errors" => [%{"index" => 2, "reason" => "boom"}]}
          ]
        }
      }

      html =
        render_component(&WorkflowComponents.batch_step_card/1,
          step: step,
          batch_progress: nil,
          iterate_progress: nil,
          node_params: %{}
        )

      assert html =~ "Chunk Results (1)"
      assert html =~ "✓ 1"
      assert html =~ "✗ 1"
    end

    test "batch_step_card renders process/post lanes with active and pending chip states" do
      step = %{
        id: "sr-b3",
        step_name: "batch_live",
        step_index: 0,
        status: "running",
        logs: [],
        results: %{},
        input: %{"x" => 1},
        errors: nil,
        started_at: DateTime.utc_now(),
        finished_at: nil
      }

      html =
        render_component(&WorkflowComponents.batch_step_card/1,
          step: step,
          batch_progress: %{
            current_chunk: 1,
            total_chunks: 2,
            successful_chunks: 0,
            failed_chunks: 0,
            phase: :process,
            current_step: 0
          },
          iterate_progress: %{current_item: 1, total_items: 2, current_step: 0},
          node_params: %{
            "process" => [
              %{"name" => "p1", "module" => "Some.Step"},
              %{
                "name" => "p2_iter",
                "module" => "Zaq.Agent.Tools.Workflow.Iterate",
                "params" => %{"pipeline" => [%{"name" => "ip1"}, %{"name" => "ip2"}]}
              }
            ],
            "post_process" => [%{"name" => "post1", "module" => "Some.Post"}]
          }
        )

      assert html =~ "Process"
      assert html =~ "Post"
      assert html =~ "ip1"
      assert html =~ "ip2"
      assert html =~ "Input"
    end

    test "iterate_step_card renders running iterate progress counters" do
      step = %{
        id: "sr-i1",
        step_name: "iterate_step",
        step_index: 0,
        status: "running",
        logs: [],
        results: %{},
        input: %{},
        errors: nil,
        started_at: DateTime.utc_now(),
        finished_at: nil
      }

      html =
        render_component(&WorkflowComponents.iterate_step_card/1,
          step: step,
          iterate_progress: %{current_item: 3, total_items: 7, current_step: 0},
          node_params: %{"pipeline" => [%{"name" => "a1"}, %{"name" => "a2"}]}
        )

      assert html =~ "3 / 7"
      assert html =~ "Items"
    end

    test "iterate_step_card renders pipeline chips and collapsible input/output sections" do
      step = %{
        id: "sr-i3",
        step_name: "iterate_done",
        step_index: 0,
        status: "completed",
        logs: [%{"event" => "step_ok", "reason" => "ok"}],
        results: %{"results" => [%{"id" => 1}], "errors" => []},
        input: %{"payload" => "abc"},
        errors: nil,
        started_at: ~U[2024-01-01 00:00:00Z],
        finished_at: ~U[2024-01-01 00:00:01Z]
      }

      html =
        render_component(&WorkflowComponents.iterate_step_card/1,
          step: step,
          iterate_progress: nil,
          node_params: %{"pipeline" => [%{"name" => "first"}, %{"name" => "second"}]}
        )

      assert html =~ "Pipeline (per item)"
      assert html =~ "first"
      assert html =~ "second"
      assert html =~ "Input"
      assert html =~ "Output"
      assert html =~ "step_ok"
    end

    test "iterate_step_card renders failed error panel when errors exist" do
      step = %{
        id: "sr-i2",
        step_name: "iterate_failed",
        step_index: 0,
        status: "failed",
        logs: [],
        results: %{},
        input: %{},
        errors: %{"reason" => "broken"},
        started_at: ~U[2024-01-01 00:00:00Z],
        finished_at: ~U[2024-01-01 00:00:01Z]
      }

      html =
        render_component(&WorkflowComponents.iterate_step_card/1,
          step: step,
          iterate_progress: nil,
          node_params: %{}
        )

      assert html =~ "Error"
      assert html =~ "broken"
    end
  end
end
