defmodule ZaqWeb.Live.BO.AI.WorkflowRunLiveTest do
  use ZaqWeb.ConnCase, async: false

  import Mox
  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures

  alias Zaq.Accounts
  alias Zaq.Engine.Api
  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.Step.Run, as: StepRun
  alias Zaq.Engine.Workflows.WorkflowRunAgent
  alias Zaq.Repo

  setup :verify_on_exit!

  setup %{conn: conn} do
    user = user_fixture(%{username: "wf-run-test-#{System.unique_integer([:positive])}"})
    {:ok, user} = Accounts.change_password(user, %{password: "StrongPass1!"})
    stub(Zaq.NodeRouterMock, :find_node, fn _supervisor -> :services@localhost end)

    stub(Zaq.NodeRouterMock, :dispatch, fn event ->
      case event.request do
        %{module: mod, function: fun, args: args} when is_atom(mod) and is_atom(fun) ->
          %{event | response: apply(mod, fun, args)}

        %{action: action} when is_binary(action) ->
          Api.handle_event(event, :workflow, nil)

        _ ->
          event
      end
    end)

    conn = init_test_session(conn, %{user_id: user.id})
    %{conn: conn}
  end

  @valid_node %{
    name: "fetch",
    type: "action",
    module: "Zaq.Engine.Workflows.Test.InboxWithResults",
    params: %{},
    index: 0
  }
  @valid_source_event %{
    "request" => nil,
    "assigns" => %{"trigger_type" => "manual"},
    "trace_id" => Ecto.UUID.generate()
  }

  defp workflow_fixture(attrs) do
    {:ok, w} =
      Workflows.create_workflow(
        Map.merge(%{name: "Run Workflow", status: "draft", nodes: [@valid_node]}, attrs)
      )

    w
  end

  defp run_fixture(workflow, attrs \\ %{}) do
    {:ok, run} = Workflows.create_run(workflow, @valid_source_event)
    # Start as "running" so the LiveView does not fire start_run in a background
    # Task that would fail to acquire the test sandbox connection.
    {:ok, run} = Workflows.update_run(run, Map.merge(%{status: "running"}, attrs))
    run
  end

  defp step_run_fixture(run, attrs) do
    StepRun
    |> struct()
    |> StepRun.changeset(
      Map.merge(
        %{
          workflow_run_id: run.id,
          step_name: "fetch",
          step_index: 0,
          status: "completed",
          logs: [],
          started_at: DateTime.utc_now(),
          finished_at: DateTime.utc_now()
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  describe "mount" do
    test "renders run status badge and short run ID in page", %{conn: conn} do
      workflow = workflow_fixture(%{nodes: [@valid_node]})
      run = run_fixture(workflow)

      {:ok, _view, html} = live(conn, ~p"/bo/workflows/#{workflow.id}/runs/#{run.id}")

      short_id = String.slice(run.id, 0, 8)
      assert html =~ short_id
      assert html =~ run.status
    end

    test "renders breadcrumb with workflow name", %{conn: conn} do
      workflow = workflow_fixture(%{name: "Breadcrumb Workflow", nodes: [@valid_node]})
      run = run_fixture(workflow)

      {:ok, _view, html} = live(conn, ~p"/bo/workflows/#{workflow.id}/runs/#{run.id}")

      assert html =~ "Breadcrumb Workflow"
      assert html =~ "Workflows"
    end

    test "renders 'Execution Path' section heading", %{conn: conn} do
      workflow = workflow_fixture(%{nodes: [@valid_node]})
      run = run_fixture(workflow)

      {:ok, _view, html} = live(conn, ~p"/bo/workflows/#{workflow.id}/runs/#{run.id}")

      assert html =~ "Execution Path"
    end

    test "renders SVG dag in Execution Path when workflow has nodes", %{conn: conn} do
      workflow = workflow_fixture(%{nodes: [@valid_node]})
      run = run_fixture(workflow)

      {:ok, _view, html} = live(conn, ~p"/bo/workflows/#{workflow.id}/runs/#{run.id}")

      assert html =~ "<svg"
    end

    test "renders step cards for each step_run", %{conn: conn} do
      workflow = workflow_fixture(%{nodes: [@valid_node]})
      run = run_fixture(workflow)
      step_run_fixture(run, %{step_name: "fetch", step_index: 0, status: "completed"})

      {:ok, _view, html} = live(conn, ~p"/bo/workflows/#{workflow.id}/runs/#{run.id}")

      assert html =~ "fetch"
    end

    test "shows step name and status badge per step", %{conn: conn} do
      workflow = workflow_fixture(%{nodes: [@valid_node]})
      run = run_fixture(workflow)
      step_run_fixture(run, %{step_name: "fetch", step_index: 0, status: "completed"})

      {:ok, view, _html} = live(conn, ~p"/bo/workflows/#{workflow.id}/runs/#{run.id}")

      # Cards are hidden until a node is selected.
      render_click(view, "select_step", %{"step_name" => "fetch"})
      html = render(view)

      assert html =~ "fetch"
      assert html =~ "completed"
    end

    test "shows log entries for a step with logs", %{conn: conn} do
      workflow = workflow_fixture(%{nodes: [@valid_node]})
      run = run_fixture(workflow)

      step_run_fixture(run, %{
        step_name: "fetch",
        step_index: 0,
        status: "completed",
        logs: [%{"event" => "step_ok", "duration_ms" => 42, "reason" => "Processing item"}]
      })

      {:ok, view, _html} = live(conn, ~p"/bo/workflows/#{workflow.id}/runs/#{run.id}")

      render_click(view, "select_step", %{"step_name" => "fetch"})
      html = render(view)

      assert html =~ "step_ok"
      assert html =~ "Processing item"
    end

    test "shows error panel for a failed step", %{conn: conn} do
      workflow = workflow_fixture(%{nodes: [@valid_node]})
      run = run_fixture(workflow)

      step_run_fixture(run, %{
        step_name: "fetch",
        step_index: 0,
        status: "failed",
        errors: %{"reason" => "timeout"}
      })

      {:ok, view, _html} = live(conn, ~p"/bo/workflows/#{workflow.id}/runs/#{run.id}")

      render_click(view, "select_step", %{"step_name" => "fetch"})
      html = render(view)

      assert html =~ "Error"
      assert html =~ "timeout"
    end

    test "redirects to workflow detail if run_id is invalid", %{conn: conn} do
      workflow = workflow_fixture(%{nodes: [@valid_node]})
      fake_run_id = Ecto.UUID.generate()

      assert {:error, {:live_redirect, %{to: path}}} =
               live(conn, ~p"/bo/workflows/#{workflow.id}/runs/#{fake_run_id}")

      assert path == "/bo/workflows/#{workflow.id}"
    end
  end

  @ok_module "Zaq.Engine.Workflows.Test.OkAction"
  @hitl_module "Zaq.Engine.Workflows.Steps.HumanInTheLoop"

  defp hitl_workflow_fixture do
    {:ok, wf} =
      Workflows.create_workflow(%{
        name: "hitl-live-#{System.unique_integer()}",
        status: "active",
        nodes: [
          %{name: "step_a", type: "action", module: @ok_module, params: %{}, index: 0},
          %{name: "hitl", type: "action", module: @hitl_module, params: %{}, index: 1}
        ],
        edges: [%{from: "step_a", to: "hitl"}]
      })

    wf
  end

  defp hitl_workflow_with_message_fixture do
    {:ok, wf} =
      Workflows.create_workflow(%{
        name: "hitl-msg-#{System.unique_integer()}",
        status: "active",
        nodes: [
          %{name: "step_a", type: "action", module: @ok_module, params: %{}, index: 0},
          %{
            name: "hitl",
            type: "action",
            module: @hitl_module,
            params: %{"message" => "Please review before proceeding."},
            index: 1
          }
        ],
        edges: [%{from: "step_a", to: "hitl"}]
      })

    wf
  end

  defp waiting_run_fixture(workflow) do
    {:ok, run} = Workflows.create_run(workflow, @valid_source_event)
    {:ok, waiting_run} = WorkflowRunAgent.execute(run)
    assert waiting_run.status == "waiting"
    waiting_run
  end

  describe "HITL approve/reject" do
    test "approve button renders when run is waiting", %{conn: conn} do
      workflow = workflow_fixture(%{nodes: [@valid_node]})
      run = run_fixture(workflow, %{status: "waiting"})

      {:ok, _view, html} = live(conn, ~p"/bo/workflows/#{workflow.id}/runs/#{run.id}")

      assert html =~ "phx-click=\"approve_step\""
      assert html =~ "phx-click=\"reject_step\""
    end

    test "approve button does not render when run is running", %{conn: conn} do
      workflow = workflow_fixture(%{nodes: [@valid_node]})
      run = run_fixture(workflow)

      {:ok, _view, html} = live(conn, ~p"/bo/workflows/#{workflow.id}/runs/#{run.id}")

      refute html =~ "phx-click=\"approve_step\""
    end

    test "clicking approve_step dispatches approval and updates run status", %{conn: conn} do
      workflow = hitl_workflow_fixture()
      waiting_run = waiting_run_fixture(workflow)

      {:ok, view, _html} = live(conn, ~p"/bo/workflows/#{workflow.id}/runs/#{waiting_run.id}")

      view |> element("button[phx-click='approve_step']") |> render_click()

      html = render(view)
      assert html =~ "completed"
    end

    test "clicking reject_step dispatches rejection and updates run status", %{conn: conn} do
      workflow = hitl_workflow_fixture()
      waiting_run = waiting_run_fixture(workflow)

      {:ok, view, _html} = live(conn, ~p"/bo/workflows/#{workflow.id}/runs/#{waiting_run.id}")

      view |> element("button[phx-click='reject_step']") |> render_click()

      html = render(view)
      assert html =~ "failed"
    end
  end

  describe "live PubSub updates" do
    test "broadcasting {:batch_progress, step_name, progress} updates view without crashing", %{
      conn: conn
    } do
      workflow =
        workflow_fixture(%{
          nodes: [
            %{
              name: "batch_step",
              type: "action",
              module: "Zaq.Agent.Tools.Workflow.Batch",
              params: %{},
              index: 0
            }
          ]
        })

      run = run_fixture(workflow)
      step_run_fixture(run, %{step_name: "batch_step", step_index: 0, status: "running"})
      {:ok, view, _html} = live(conn, ~p"/bo/workflows/#{workflow.id}/runs/#{run.id}")

      Phoenix.PubSub.broadcast(
        Zaq.PubSub,
        "workflow_run:#{run.id}",
        {:batch_progress, "batch_step",
         %{current_chunk: 2, total_chunks: 4, successful_chunks: 1, failed_chunks: 1}}
      )

      html = render(view)
      assert html =~ run.status
    end

    test "broadcasting {:iterate_progress, step_name, progress} updates view without crashing", %{
      conn: conn
    } do
      # The node module is incidental — this test only needs a viewable run to
      # prove the LiveView tolerates a legacy `{:iterate_progress, …}` broadcast
      # without crashing. (Iterate was deleted in Task 8; the `map` model no longer
      # emits iterate_progress at all.)
      workflow = workflow_fixture(%{nodes: [@valid_node]})

      run = run_fixture(workflow)
      step_run_fixture(run, %{step_name: "iterate_step", step_index: 0, status: "running"})
      {:ok, view, _html} = live(conn, ~p"/bo/workflows/#{workflow.id}/runs/#{run.id}")

      Phoenix.PubSub.broadcast(
        Zaq.PubSub,
        "workflow_run:#{run.id}",
        {:iterate_progress, "iterate_step", %{current_item: 3, total_items: 7, current_step: 0}}
      )

      html = render(view)
      assert html =~ run.status
    end

    test "broadcasting {:run_updated, run} updates run status on page", %{conn: conn} do
      workflow = workflow_fixture(%{nodes: [@valid_node]})
      run = run_fixture(workflow)

      {:ok, view, _html} = live(conn, ~p"/bo/workflows/#{workflow.id}/runs/#{run.id}")

      updated_run = %{run | status: "completed"}
      Phoenix.PubSub.broadcast(Zaq.PubSub, "workflow_run:#{run.id}", {:run_updated, updated_run})

      html = render(view)
      assert html =~ "completed"
    end

    test "broadcasting {:step_updated, step_run} adds the step to the page", %{conn: conn} do
      workflow = workflow_fixture(%{nodes: [@valid_node]})
      run = run_fixture(workflow)

      {:ok, view, _html} = live(conn, ~p"/bo/workflows/#{workflow.id}/runs/#{run.id}")

      step_run = step_run_fixture(run, %{step_name: "fetch", step_index: 0, status: "running"})

      Phoenix.PubSub.broadcast(Zaq.PubSub, "workflow_run:#{run.id}", {:step_updated, step_run})

      html = render(view)
      assert html =~ "fetch"
    end

    test "broadcasting {:step_updated, step_run} updates an existing step on the page", %{
      conn: conn
    } do
      workflow = workflow_fixture(%{nodes: [@valid_node]})
      run = run_fixture(workflow)
      step_run = step_run_fixture(run, %{step_name: "fetch", step_index: 0, status: "running"})

      {:ok, view, _html} = live(conn, ~p"/bo/workflows/#{workflow.id}/runs/#{run.id}")

      updated_step = %{step_run | status: "completed"}

      Phoenix.PubSub.broadcast(
        Zaq.PubSub,
        "workflow_run:#{run.id}",
        {:step_updated, updated_step}
      )

      html = render(view)
      assert html =~ "completed"
    end

    test "broadcasting {:run_updated} with non-waiting status clears approval", %{conn: conn} do
      workflow = workflow_fixture(%{nodes: [@valid_node]})
      run = run_fixture(workflow, %{status: "waiting"})

      {:ok, view, _html} = live(conn, ~p"/bo/workflows/#{workflow.id}/runs/#{run.id}")

      completed_run = %{run | status: "completed"}

      Phoenix.PubSub.broadcast(
        Zaq.PubSub,
        "workflow_run:#{run.id}",
        {:run_updated, completed_run}
      )

      html = render(view)
      assert html =~ "completed"
    end

    test "broadcasting {:run_updated} with waiting status refreshes approval details", %{
      conn: conn
    } do
      workflow = hitl_workflow_with_message_fixture()
      waiting_run = waiting_run_fixture(workflow)
      {:ok, view, _html} = live(conn, ~p"/bo/workflows/#{workflow.id}/runs/#{waiting_run.id}")

      Phoenix.PubSub.broadcast(
        Zaq.PubSub,
        "workflow_run:#{waiting_run.id}",
        {:run_updated, %{waiting_run | status: "waiting"}}
      )

      assert render(view) =~ "Please review before proceeding."
    end

    test "tick message updates the now assign without crashing", %{conn: conn} do
      workflow = workflow_fixture(%{nodes: [@valid_node]})
      run = run_fixture(workflow)

      {:ok, view, _html} = live(conn, ~p"/bo/workflows/#{workflow.id}/runs/#{run.id}")

      send(view.pid, :tick)
      assert render(view) =~ run.status
    end

    test "unknown info messages are ignored", %{conn: conn} do
      workflow = workflow_fixture(%{nodes: [@valid_node]})
      run = run_fixture(workflow)

      {:ok, view, _html} = live(conn, ~p"/bo/workflows/#{workflow.id}/runs/#{run.id}")

      send(view.pid, :unexpected_message)
      assert render(view) =~ run.status
    end

    test "handle_info {:start_run, run} fires without crashing", %{conn: conn} do
      workflow = workflow_fixture(%{nodes: [@valid_node]})
      run = run_fixture(workflow)

      {:ok, view, _html} = live(conn, ~p"/bo/workflows/#{workflow.id}/runs/#{run.id}")

      send(view.pid, {:start_run, run})
      assert render(view) =~ run.status
    end
  end

  describe "map aggregate rendering (Part 3, Step 9)" do
    @map_node %{
      name: "m",
      type: "map",
      params: %{
        "over" => "items",
        "body" => [
          %{
            "name" => "ok",
            "type" => "action",
            "module" => "Zaq.Engine.Workflows.Test.OkAction",
            "params" => %{}
          }
        ]
      },
      index: 0
    }

    defp map_run_with_rows(conn, workflow) do
      run = run_fixture(workflow)

      # Aggregate row (MapCollect output): 2 ok, 1 failed.
      step_run_fixture(run, %{
        step_name: "m",
        step_index: 0,
        status: "completed",
        results: %{
          "results" => [%{"index" => 0}, %{"index" => 2}],
          "errors" => [%{"index" => 1, "reason" => "boom"}],
          "count" => 3
        }
      })

      # The per-fork failure row for item 1.
      step_run_fixture(run, %{
        step_name: "m/ok[1]",
        step_index: 0,
        status: "failed_fatal",
        errors: %{"reason" => "boom"}
      })

      {:ok, view, _html} = live(conn, ~p"/bo/workflows/#{workflow.id}/runs/#{run.id}")
      render_click(view, "select_step", %{"step_name" => "m"})
    end

    test "renders the aggregate node with ok/failed counts", %{conn: conn} do
      workflow = workflow_fixture(%{nodes: [@map_node]})
      html = map_run_with_rows(conn, workflow)

      assert html =~ "2 ok"
      assert html =~ "1 failed"
    end

    test "renders a visible failed fork row with its reason", %{conn: conn} do
      workflow = workflow_fixture(%{nodes: [@map_node]})
      html = map_run_with_rows(conn, workflow)

      assert html =~ "Failed items"
      assert html =~ "m/ok[1]"
      assert html =~ "boom"
    end

    test "the aggregate card lists the per-item body pipeline", %{conn: conn} do
      workflow = workflow_fixture(%{nodes: [@map_node]})
      html = map_run_with_rows(conn, workflow)

      # the body step name is shown as a per-item pipeline chip
      assert html =~ "Per item"
      assert html =~ "ok"
    end

    test "the DAG renders the map node with a MAP badge", %{conn: conn} do
      workflow = workflow_fixture(%{nodes: [@map_node]})
      run = run_fixture(workflow)
      {:ok, _view, html} = live(conn, ~p"/bo/workflows/#{workflow.id}/runs/#{run.id}")

      # map nodes get the iteration treatment in the run-graph (MAP badge)
      assert html =~ "MAP"
    end
  end

  describe "cancel_run event" do
    test "cancel_run succeeds for a running run and updates status", %{conn: conn} do
      workflow = workflow_fixture(%{nodes: [@valid_node]})
      run = run_fixture(workflow)

      {:ok, view, _html} = live(conn, ~p"/bo/workflows/#{workflow.id}/runs/#{run.id}")

      html = view |> element("button[phx-click='cancel_run']") |> render_click()
      assert html =~ "cancelled"
    end

    test "cancel_run shows error flash when run is already finished", %{conn: conn} do
      workflow = workflow_fixture(%{nodes: [@valid_node]})
      # A completed run — cancel_run returns {:error, :already_finished} for terminal statuses
      run = run_fixture(workflow, %{status: "completed"})

      {:ok, view, _html} = live(conn, ~p"/bo/workflows/#{workflow.id}/runs/#{run.id}")
      # Fire event directly — Cancel button is not rendered for completed runs
      html = render_click(view, "cancel_run", %{})
      assert html =~ "Run has already finished."
    end

    test "cancel_run remains responsive when dispatch returns unexpected value", %{conn: conn} do
      workflow = workflow_fixture(%{nodes: [@valid_node]})
      run = run_fixture(workflow)

      stub(Zaq.NodeRouterMock, :dispatch, fn event ->
        case event.request do
          %{function: :cancel_run} -> %{event | response: :error}
          %{module: mod, function: fun, args: args} -> %{event | response: apply(mod, fun, args)}
          %{action: action} when is_binary(action) -> Api.handle_event(event, :workflow, nil)
          _ -> event
        end
      end)

      {:ok, view, _html} = live(conn, ~p"/bo/workflows/#{workflow.id}/runs/#{run.id}")
      html = render_click(view, "cancel_run", %{})
      assert html =~ "Run"
    end
  end

  describe "pause_run event" do
    test "pause_run succeeds for a running run and updates status", %{conn: conn} do
      workflow = workflow_fixture(%{nodes: [@valid_node]})
      run = run_fixture(workflow)

      stub(Zaq.NodeRouterMock, :dispatch, fn event ->
        case event.request do
          %{function: :pause_run} -> %{event | response: {:ok, %{run | status: "paused"}}}
          %{module: mod, function: fun, args: args} -> %{event | response: apply(mod, fun, args)}
          _ -> event
        end
      end)

      {:ok, view, _html} = live(conn, ~p"/bo/workflows/#{workflow.id}/runs/#{run.id}")
      html = view |> element("button[phx-click='pause_run']") |> render_click()
      assert html =~ "paused"
    end

    test "pause_run shows error flash when run is not running", %{conn: conn} do
      workflow = workflow_fixture(%{nodes: [@valid_node]})
      # A paused run — pause_run returns {:error, :not_running} for non-"running" statuses
      run = run_fixture(workflow, %{status: "paused"})

      {:ok, view, _html} = live(conn, ~p"/bo/workflows/#{workflow.id}/runs/#{run.id}")
      # Fire event directly — Pause button is only rendered when status == "running"
      html = render_click(view, "pause_run", %{})
      assert html =~ "Run is not currently running."
    end

    test "pause_run remains responsive when dispatch returns unexpected value", %{conn: conn} do
      workflow = workflow_fixture(%{nodes: [@valid_node]})
      run = run_fixture(workflow)

      stub(Zaq.NodeRouterMock, :dispatch, fn event ->
        case event.request do
          %{function: :pause_run} -> %{event | response: :error}
          %{module: mod, function: fun, args: args} -> %{event | response: apply(mod, fun, args)}
          %{action: action} when is_binary(action) -> Api.handle_event(event, :workflow, nil)
          _ -> event
        end
      end)

      {:ok, view, _html} = live(conn, ~p"/bo/workflows/#{workflow.id}/runs/#{run.id}")
      html = render_click(view, "pause_run", %{})
      assert html =~ "Run"
    end
  end

  describe "resume_run event" do
    test "resume_run fires a background task without crashing the view", %{conn: conn} do
      workflow = workflow_fixture(%{nodes: [@valid_node]})
      run = run_fixture(workflow, %{status: "paused"})

      {:ok, view, html} = live(conn, ~p"/bo/workflows/#{workflow.id}/runs/#{run.id}")
      assert html =~ "Resume"

      view |> element("button[phx-click='resume_run']") |> render_click()
      assert render(view) =~ "paused"
    end
  end

  describe "approve/reject failure cases" do
    test "approve_step shows error flash when dispatch fails", %{conn: conn} do
      workflow = workflow_fixture(%{nodes: [@valid_node]})
      run = run_fixture(workflow, %{status: "waiting"})

      stub(Zaq.NodeRouterMock, :dispatch, fn event ->
        case event.request do
          %{action: "run.approve"} -> %{event | response: {:error, :failed}}
          %{module: mod, function: fun, args: args} -> %{event | response: apply(mod, fun, args)}
          %{action: action} when is_binary(action) -> Api.handle_event(event, :workflow, nil)
          _ -> event
        end
      end)

      {:ok, view, _html} = live(conn, ~p"/bo/workflows/#{workflow.id}/runs/#{run.id}")
      html = view |> element("button[phx-click='approve_step']") |> render_click()
      assert html =~ "Failed to approve run."
    end

    test "reject_step shows error flash when dispatch fails", %{conn: conn} do
      workflow = workflow_fixture(%{nodes: [@valid_node]})
      run = run_fixture(workflow, %{status: "waiting"})

      stub(Zaq.NodeRouterMock, :dispatch, fn event ->
        case event.request do
          %{action: "run.reject"} -> %{event | response: {:error, :failed}}
          %{module: mod, function: fun, args: args} -> %{event | response: apply(mod, fun, args)}
          %{action: action} when is_binary(action) -> Api.handle_event(event, :workflow, nil)
          _ -> event
        end
      end)

      {:ok, view, _html} = live(conn, ~p"/bo/workflows/#{workflow.id}/runs/#{run.id}")
      html = view |> element("button[phx-click='reject_step']") |> render_click()
      assert html =~ "Failed to reject run."
    end
  end

  describe "approval card with message" do
    test "renders approval message when run is waiting and approval has a message", %{conn: conn} do
      workflow = hitl_workflow_with_message_fixture()
      waiting_run = waiting_run_fixture(workflow)
      {:ok, _view, html} = live(conn, ~p"/bo/workflows/#{workflow.id}/runs/#{waiting_run.id}")
      assert html =~ "Please review before proceeding."
    end

    test "selected step renders input and output json panels", %{conn: conn} do
      workflow = workflow_fixture(%{nodes: [@valid_node]})
      run = run_fixture(workflow)

      step_run_fixture(run, %{
        step_name: "fetch",
        step_index: 0,
        status: "completed",
        input: %{"query" => "abc"},
        results: %{"count" => 1}
      })

      {:ok, view, _html} = live(conn, ~p"/bo/workflows/#{workflow.id}/runs/#{run.id}")
      render_click(view, "select_step", %{"step_name" => "fetch"})
      html = render(view)

      assert html =~ "step-input-chevron-"
      assert html =~ "jt-step-input-"
      assert html =~ "step-chevron-"
      assert html =~ "jt-step-"
    end
  end
end
