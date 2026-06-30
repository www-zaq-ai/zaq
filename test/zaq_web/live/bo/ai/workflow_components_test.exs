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

    test "renders interrupted status with yellow CSS class" do
      html = render_component(&WorkflowComponents.run_status_badge/1, status: "interrupted")
      assert html =~ "interrupted"
      assert html =~ "yellow"
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

    test "freezes paused duration at updated_at" do
      started = ~U[2024-01-01 10:00:00Z]
      updated_at = ~U[2024-01-01 10:00:30Z]
      now = ~U[2024-01-01 10:10:00Z]

      run = %{started_at: started, finished_at: nil, status: "paused", updated_at: updated_at}

      html = render_component(&WorkflowComponents.run_duration/1, run: run, now: now)

      assert html =~ "30s"
      refute html =~ "10m"
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

    test "batch node renders its flat process steps and the post_process label" do
      node = %{
        name: "batch",
        type: "action",
        module: "Zaq.Agent.Tools.Workflow.Batch",
        index: 0,
        params: %{
          "delivery" => "item",
          "process" => [
            %{"name" => "plain_step", "module" => "SomeMod"},
            %{"name" => "another_step", "module" => "OtherMod"}
          ],
          "post_process" => [%{"name" => "post_1", "module" => "SomePost"}]
        }
      }

      html = render_component(&WorkflowComponents.workflow_dag/1, nodes: [node], edges: [])
      assert html =~ "POST PROCESS"
      assert html =~ "plain_step"
      assert html =~ "another_step"
    end

    test "map node renders its body pipeline as stacked mini nodes" do
      node = %{
        name: "m",
        type: "map",
        index: 0,
        params: %{"body" => [%{"name" => "a"}, %{"name" => "b"}, %{"name" => "c"}]}
      }

      html = render_component(&WorkflowComponents.workflow_dag/1, nodes: [node], edges: [])
      assert html =~ "MAP"
      assert html =~ "a"
      assert html =~ "b"
      assert html =~ "c"
    end

    test "injects clickable start node for start edge" do
      html =
        render_component(&WorkflowComponents.workflow_dag/1,
          nodes: [@node],
          edges: [%{from: "start", to: "fetch"}],
          on_node_click: true,
          selected_step: "start"
        )

      assert html =~ "start"
      assert html =~ "#eef2ff"
      assert html =~ "#6366f1"
      assert html =~ ~s(phx-click="select_step")
      assert html =~ ~s(phx-value-step_name="start")
    end

    test "renders batch node with empty params as plain batch shell" do
      node = %{
        name: "batch",
        type: "action",
        module: "Zaq.Agent.Tools.Workflow.Batch",
        index: 0,
        params: %{}
      }

      html = render_component(&WorkflowComponents.workflow_dag/1, nodes: [node], edges: [])

      assert html =~ "BATCH"
      refute html =~ "plain_step"
      refute html =~ "POST PROCESS"
    end

    test "handles map node with nil params and empty body params" do
      nil_params_node = %{name: "m_nil", type: "map", index: 0, params: nil}
      empty_body_node = %{name: "m_empty", type: "map", index: 0, params: %{"body" => []}}

      nil_html =
        render_component(&WorkflowComponents.workflow_dag/1, nodes: [nil_params_node], edges: [])

      empty_html =
        render_component(&WorkflowComponents.workflow_dag/1, nodes: [empty_body_node], edges: [])

      assert nil_html =~ "<svg"
      assert nil_html =~ "MAP"
      refute nil_html =~ "validate"

      assert empty_html =~ "<svg"
      assert empty_html =~ "MAP"
      refute empty_html =~ "validate"
    end

    test "renders map post_process tail" do
      node = %{
        name: "map_tail",
        type: "map",
        index: 0,
        params: %{
          "body" => [%{"name" => "validate"}],
          "post_process" => [%{"name" => "notify"}]
        }
      }

      html = render_component(&WorkflowComponents.workflow_dag/1, nodes: [node], edges: [])

      assert html =~ "validate"
      assert html =~ "notify"
      assert html =~ "<line"
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

  describe "batch_step_card/1" do
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
          step_runs: [],
          node_params: %{"process" => [%{"name" => "p1"}]}
        )

      assert html =~ "2 / 5"
      assert html =~ "Batches"
    end

    test "batch_step_card renders the completed aggregate ok/failed counts" do
      # New map-summary shape: results["results"] is the list of per-fork summaries,
      # results["errors"] the failed forks. The top "Batches" bar derives ok/✗ from them.
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
            %{"index" => 0, "status" => "completed", "result" => %{}},
            %{"index" => 2, "status" => "completed", "result" => %{}}
          ],
          "errors" => [%{"index" => 1, "reason" => "boom"}],
          "count" => 3
        }
      }

      html =
        render_component(&WorkflowComponents.batch_step_card/1,
          step: step,
          batch_progress: nil,
          step_runs: [],
          node_params: %{}
        )

      assert html =~ "Batches"
      assert html =~ "✓ 2"
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
          step_runs: [],
          node_params: %{
            "delivery" => "item",
            "process" => [
              %{"name" => "p1", "module" => "Some.Step"},
              %{"name" => "p2", "module" => "Other.Step"}
            ],
            "post_process" => [%{"name" => "post1", "module" => "Some.Post"}]
          }
        )

      assert html =~ "Process"
      assert html =~ "Post"
      assert html =~ "p1"
      assert html =~ "p2"
      assert html =~ "Input"
    end

    test "batch_step_card lists per-fork runs with their logs" do
      step = %{
        id: "sr-bf",
        step_name: "batch_fork",
        step_index: 0,
        status: "completed",
        logs: [],
        results: %{"results" => [%{"id" => 1}], "errors" => []},
        input: %{},
        errors: nil,
        started_at: ~U[2024-01-01 00:00:00Z],
        finished_at: ~U[2024-01-01 00:00:02Z]
      }

      # Two fan-out units (indices 0 and 1), each with two body steps. The list
      # groups by index — every [0] row together, then every [1] row together —
      # not by body-step name.
      forks = [
        %{
          id: "f0a",
          step_name: "batch_fork/check[0]",
          step_index: 0,
          status: "completed",
          logs: [%{"event" => "step_ok", "reason" => "ok0"}],
          errors: nil,
          started_at: ~U[2024-01-01 00:00:00Z],
          finished_at: ~U[2024-01-01 00:00:01Z]
        },
        %{
          id: "f0b",
          step_name: "batch_fork/dispatch[0]",
          step_index: 0,
          status: "completed",
          logs: [%{"event" => "step_ok", "reason" => "sent"}],
          errors: nil,
          started_at: ~U[2024-01-01 00:00:01Z],
          finished_at: ~U[2024-01-01 00:00:02Z]
        },
        %{
          id: "f1a",
          step_name: "batch_fork/check[1]",
          step_index: 0,
          status: "failed_fatal",
          logs: [],
          errors: %{"reason" => "boom"},
          started_at: ~U[2024-01-01 00:00:00Z],
          finished_at: ~U[2024-01-01 00:00:01Z]
        }
      ]

      html =
        render_component(&WorkflowComponents.batch_step_card/1,
          step: step,
          batch_progress: nil,
          step_runs: forks,
          node_params: %{"delivery" => "item", "process" => [%{"name" => "dispatch"}]}
        )

      # Two index groups → count is the number of fan-out units, not rows.
      assert html =~ "Per-batch runs (2)"
      assert html =~ "Batch #0"
      assert html =~ "Batch #1"
      assert html =~ "batch_fork/dispatch[0]"
      assert html =~ "batch_fork/check[1]"
      assert html =~ "step_ok"
      assert html =~ "boom"
      assert html =~ "per item"

      # Index grouping: both [0] rows precede the [1] row.
      assert :binary.match(html, "batch_fork/dispatch[0]") <
               :binary.match(html, "batch_fork/check[1]")
    end

    test "marks all process chips done during post_process phase" do
      step = %{
        id: "sr-b4",
        step_name: "batch_post",
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
            phase: :post_process,
            current_step: 0,
            current_chunk: 1,
            total_chunks: 1,
            successful_chunks: 0,
            failed_chunks: 0
          },
          step_runs: [],
          node_params: %{"process" => [%{"name" => "p1"}]}
        )

      assert html =~ "p1"
      assert html =~ "text-emerald-700 bg-emerald-100"
    end

    test "marks post chips done active pending" do
      step = %{
        id: "sr-b5",
        step_name: "batch_post_states",
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
            phase: :post_process,
            current_step: 1,
            current_chunk: 1,
            total_chunks: 1
          },
          step_runs: [],
          node_params: %{
            "process" => [%{"name" => "p1"}],
            "post_process" => [%{"name" => "post1"}, %{"name" => "post2"}, %{"name" => "post3"}]
          }
        )

      assert html =~ "text-emerald-700 bg-emerald-100"
      assert html =~ "border-emerald-400"
      assert html =~ "text-black/30 bg-black/[0.03] border-black/[0.06]"
      assert html =~ "animate-pulse"
    end

    test "renders logs and failed error block" do
      step = %{
        id: "sr-b6",
        step_name: "batch_logs",
        step_index: 0,
        status: "failed",
        logs: [%{"event" => "item_error", "reason" => "bad item"}],
        results: %{},
        input: %{},
        errors: %{"reason" => "fatal"},
        started_at: ~U[2024-01-01 00:00:00Z],
        finished_at: ~U[2024-01-01 00:00:01Z]
      }

      html =
        render_component(&WorkflowComponents.batch_step_card/1,
          step: step,
          batch_progress: nil,
          step_runs: [],
          node_params: %{}
        )

      assert html =~ "Logs"
      assert html =~ "item_error"
      assert html =~ "bad item"
      assert html =~ "Error"
      assert html =~ "fatal"
    end

    test "handles unknown and non-map delivery params" do
      step = %{
        id: "sr-b7",
        step_name: "batch_unknown",
        step_index: 0,
        status: "running",
        logs: [],
        results: %{},
        input: %{},
        errors: nil,
        started_at: DateTime.utc_now(),
        finished_at: nil
      }

      unknown_html =
        render_component(&WorkflowComponents.batch_step_card/1,
          step: step,
          batch_progress: nil,
          step_runs: [],
          node_params: %{"delivery" => "unknown"}
        )

      nil_html =
        render_component(&WorkflowComponents.batch_step_card/1,
          step: step,
          batch_progress: nil,
          step_runs: [],
          node_params: nil
        )

      refute unknown_html =~ "per item"
      refute unknown_html =~ "per batch"
      assert nil_html =~ "BATCH"
      refute nil_html =~ "per item"
      refute nil_html =~ "per batch"
    end

    test "covers progress fallbacks" do
      running_step = %{
        id: "sr-b8",
        step_name: "batch_fallbacks",
        step_index: 0,
        status: "running",
        logs: [],
        results: nil,
        input: %{},
        errors: nil,
        started_at: DateTime.utc_now(),
        finished_at: nil
      }

      paused_step = %{running_step | id: "sr-b9", status: "paused"}
      completed_nil = %{running_step | id: "sr-b10", status: "completed", results: nil}

      completed_empty = %{
        running_step
        | id: "sr-b11",
          status: "completed",
          results: %{"results" => []}
      }

      running_html =
        render_component(&WorkflowComponents.batch_step_card/1,
          step: running_step,
          batch_progress: nil,
          step_runs: [],
          node_params: %{}
        )

      paused_html =
        render_component(&WorkflowComponents.batch_step_card/1,
          step: paused_step,
          batch_progress: nil,
          step_runs: [],
          node_params: %{}
        )

      completed_nil_html =
        render_component(&WorkflowComponents.batch_step_card/1,
          step: completed_nil,
          batch_progress: nil,
          step_runs: [],
          node_params: %{}
        )

      completed_empty_html =
        render_component(&WorkflowComponents.batch_step_card/1,
          step: completed_empty,
          batch_progress: nil,
          step_runs: [],
          node_params: %{}
        )

      assert running_html =~ "initializing"
      refute paused_html =~ "Batches"
      refute completed_nil_html =~ "Batches"
      refute completed_empty_html =~ "Batches"
    end

    test "handles atom process key safely" do
      step = %{
        id: "sr-b12",
        step_name: "batch_atom",
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
          batch_progress: nil,
          step_runs: [],
          node_params: %{process: [%{name: "atom_step"}]}
        )

      assert html =~ "atom_step"
    end
  end

  # ---------------------------------------------------------------------------
  # map_step_card/1
  # ---------------------------------------------------------------------------

  describe "map_step_card/1" do
    test "renders body and post-process labels" do
      step = %{
        id: "sr-m1",
        step_name: "map_step",
        step_index: 0,
        status: "completed",
        logs: [],
        results: %{},
        input: %{},
        errors: nil,
        started_at: ~U[2024-01-01 00:00:00Z],
        finished_at: ~U[2024-01-01 00:00:02Z]
      }

      html =
        render_component(&WorkflowComponents.map_step_card/1,
          step: step,
          step_runs: [],
          node_params: %{
            "body" => [%{"name" => "validate"}],
            "post_process" => [%{"name" => "notify"}]
          }
        )

      assert html =~ "Per item"
      assert html =~ "validate"
      assert html =~ "then"
      assert html =~ "notify"
    end

    test "renders failed fork fallback reason and Other group" do
      step = %{
        id: "sr-m2",
        step_name: "map_node",
        step_index: 0,
        status: "failed",
        logs: [],
        results: %{},
        input: %{},
        errors: %{"reason" => "fatal"},
        started_at: ~U[2024-01-01 00:00:00Z],
        finished_at: ~U[2024-01-01 00:00:02Z]
      }

      html =
        render_component(&WorkflowComponents.map_step_card/1,
          step: step,
          step_runs: [
            %{
              step_name: "map_node/check",
              status: "failed",
              errors: nil,
              started_at: nil,
              logs: []
            }
          ],
          node_params: %{}
        )

      assert html =~ "Other"
      assert html =~ "failed"
      assert html =~ "map_node/check"
    end

    test "sorts fork rows without started_at by name" do
      step = %{
        id: "sr-m3",
        step_name: "map_sort",
        step_index: 0,
        status: "completed",
        logs: [],
        results: %{},
        input: %{},
        errors: nil,
        started_at: ~U[2024-01-01 00:00:00Z],
        finished_at: ~U[2024-01-01 00:00:02Z]
      }

      html =
        render_component(&WorkflowComponents.map_step_card/1,
          step: step,
          step_runs: [
            %{
              step_name: "map_sort/beta[0]",
              status: "completed",
              errors: nil,
              started_at: nil,
              logs: []
            },
            %{
              step_name: "map_sort/alpha[0]",
              status: "completed",
              errors: nil,
              started_at: nil,
              logs: []
            }
          ],
          node_params: %{}
        )

      assert :binary.match(html, "map_sort/alpha[0]") < :binary.match(html, "map_sort/beta[0]")
    end
  end
end
