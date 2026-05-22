defmodule ZaqWeb.Live.BO.AI.WorkflowDetailLiveTest do
  use ZaqWeb.ConnCase, async: false

  import Mox
  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures

  alias Zaq.Accounts
  alias Zaq.Engine.Workflows

  setup :verify_on_exit!

  setup %{conn: conn} do
    user = user_fixture(%{username: "wf-detail-test-#{System.unique_integer([:positive])}"})
    {:ok, user} = Accounts.change_password(user, %{password: "StrongPass1!"})
    stub(Zaq.NodeRouterMock, :find_node, fn _supervisor -> :services@localhost end)

    stub(Zaq.NodeRouterMock, :dispatch, fn event ->
      case event.request do
        %{module: mod, function: fun, args: args} when is_atom(mod) and is_atom(fun) ->
          %{event | response: apply(mod, fun, args)}

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
    module: "Zaq.Agent.Tools.Email.FetchEmails",
    params: %{},
    index: 0
  }
  @valid_source_event %{
    "request" => nil,
    "assigns" => %{"trigger_type" => "manual"},
    "trace_id" => Ecto.UUID.generate()
  }

  defp workflow_fixture(attrs \\ %{}) do
    {:ok, w} =
      Workflows.create_workflow(
        Map.merge(%{name: "Detail Workflow", status: "draft", nodes: [@valid_node]}, attrs)
      )

    w
  end

  defp run_fixture(workflow) do
    {:ok, run} = Workflows.create_run(workflow, @valid_source_event)
    run
  end

  defp trigger_fixture(workflow, attrs \\ %{}) do
    {:ok, t} =
      Workflows.create_trigger(Map.merge(%{event_name: "manual_trigger", enabled: true}, attrs))

    Workflows.assign_workflow_to_trigger(t, workflow)
    t
  end

  describe "mount" do
    test "renders workflow name and status badge", %{conn: conn} do
      workflow = workflow_fixture(%{name: "My Special Workflow", status: "draft"})
      {:ok, _view, html} = live(conn, ~p"/bo/workflows/#{workflow.id}")
      assert html =~ "My Special Workflow"
      assert html =~ "active"
    end

    test "renders 'Export Workflow' button", %{conn: conn} do
      workflow = workflow_fixture()
      {:ok, _view, html} = live(conn, ~p"/bo/workflows/#{workflow.id}")
      assert html =~ "Export Workflow"
    end

    test "renders 'Delete' button", %{conn: conn} do
      workflow = workflow_fixture()
      {:ok, _view, html} = live(conn, ~p"/bo/workflows/#{workflow.id}")
      assert html =~ "Delete"
    end

    test "renders 'Flow' section heading", %{conn: conn} do
      workflow = workflow_fixture(%{nodes: [@valid_node]})
      {:ok, _view, html} = live(conn, ~p"/bo/workflows/#{workflow.id}")
      assert html =~ "Flow"
    end

    test "renders SVG DAG when workflow has nodes", %{conn: conn} do
      workflow = workflow_fixture(%{nodes: [@valid_node]})
      {:ok, _view, html} = live(conn, ~p"/bo/workflows/#{workflow.id}")
      assert html =~ "<svg"
    end

    test "renders triggers section in the Details card", %{conn: conn} do
      workflow = workflow_fixture()
      trigger_fixture(workflow, %{type: "manual", enabled: true})
      {:ok, _view, html} = live(conn, ~p"/bo/workflows/#{workflow.id}")
      assert html =~ "Triggers"
    end

    test "renders runs count in the heading", %{conn: conn} do
      workflow = workflow_fixture(%{nodes: [@valid_node]})
      run_fixture(workflow)
      {:ok, _view, html} = live(conn, ~p"/bo/workflows/#{workflow.id}")
      assert html =~ "Runs (1)"
    end

    test "redirects to /bo/workflows when workflow id is invalid", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/bo/workflows"}}} =
               live(conn, ~p"/bo/workflows/00000000-0000-0000-0000-000000000000")
    end
  end

  describe "delete workflow" do
    test "opens delete confirmation modal on 'Delete' click", %{conn: conn} do
      workflow = workflow_fixture()
      {:ok, view, _html} = live(conn, ~p"/bo/workflows/#{workflow.id}")
      html = view |> element("button[phx-click='open_delete']") |> render_click()
      assert html =~ "delete-workflow-modal"
    end

    test "cancel_delete closes the delete modal", %{conn: conn} do
      workflow = workflow_fixture()
      {:ok, view, _html} = live(conn, ~p"/bo/workflows/#{workflow.id}")
      view |> element("button[phx-click='open_delete']") |> render_click()
      html = view |> element("button[phx-click='cancel_delete']") |> render_click()
      refute html =~ "delete-workflow-modal"
    end

    test "delete event removes workflow and redirects to /bo/workflows with flash", %{conn: conn} do
      workflow = workflow_fixture()
      {:ok, view, _html} = live(conn, ~p"/bo/workflows/#{workflow.id}")
      view |> element("button[phx-click='open_delete']") |> render_click()

      assert {:error, {:live_redirect, %{to: "/bo/workflows"}}} =
               view |> element("button[phx-click='delete']") |> render_click()

      # Verify workflow was actually deleted
      assert_raise Ecto.NoResultsError, fn -> Workflows.get_workflow!(workflow.id) end
    end
  end

  describe "pagination" do
    test "pagination controls appear when runs_total > per_page", %{conn: conn} do
      workflow = workflow_fixture(%{nodes: [@valid_node]})

      for _i <- 1..21 do
        run_fixture(workflow)
      end

      {:ok, _view, html} = live(conn, ~p"/bo/workflows/#{workflow.id}")
      assert html =~ "← Prev"
      assert html =~ "Next →"
    end

    test "pagination controls do not appear when runs_total <= per_page", %{conn: conn} do
      workflow = workflow_fixture(%{nodes: [@valid_node]})
      run_fixture(workflow)
      {:ok, _view, html} = live(conn, ~p"/bo/workflows/#{workflow.id}")
      refute html =~ "← Prev"
    end
  end

  describe "export event" do
    test "export event pushes a download event to the client", %{conn: conn} do
      workflow = workflow_fixture(%{nodes: [@valid_node]})
      {:ok, view, _html} = live(conn, ~p"/bo/workflows/#{workflow.id}")

      view |> element("button[phx-click='export']") |> render_click()

      assert_push_event(view, "download", %{filename: filename, content: _content})

      assert filename =~ "workflow-#{workflow.id}"
    end
  end

  describe "run_workflow event" do
    test "run_workflow navigates to the run page on success", %{conn: conn} do
      workflow = workflow_fixture(%{name: "Runnable", nodes: [@valid_node]})
      {:ok, view, _html} = live(conn, ~p"/bo/workflows/#{workflow.id}")

      assert {:error, {:live_redirect, %{to: path}}} =
               view |> element("button[phx-click='run_workflow']") |> render_click()

      assert path =~ "/bo/workflows/#{workflow.id}/runs/"
    end
  end

  describe "paginate event" do
    test "paginate event advances to page 2", %{conn: conn} do
      workflow = workflow_fixture(%{nodes: [@valid_node]})
      for _i <- 1..21, do: run_fixture(workflow)

      {:ok, view, html} = live(conn, ~p"/bo/workflows/#{workflow.id}")
      assert html =~ "Page 1 of"

      html = view |> element("button[phx-click='paginate'][phx-value-page='2']") |> render_click()
      assert html =~ "Page 2 of"
    end
  end

  describe "PubSub info handlers" do
    test "receiving {:run_finished, run} refreshes runs and does not crash", %{conn: conn} do
      workflow = workflow_fixture(%{nodes: [@valid_node]})
      {:ok, view, _html} = live(conn, ~p"/bo/workflows/#{workflow.id}")

      Phoenix.PubSub.broadcast(Zaq.PubSub, "workflow:#{workflow.id}", {:run_finished, %{}})

      assert render(view) =~ workflow.name
    end

    test "unknown info messages are ignored", %{conn: conn} do
      workflow = workflow_fixture()
      {:ok, view, _html} = live(conn, ~p"/bo/workflows/#{workflow.id}")

      send(view.pid, :unexpected_message)
      assert render(view) =~ workflow.name
    end
  end

  describe "rendering branches" do
    test "renders workflow description when present", %{conn: conn} do
      workflow = workflow_fixture(%{description: "My detailed description"})
      {:ok, _view, html} = live(conn, ~p"/bo/workflows/#{workflow.id}")
      assert html =~ "My detailed description"
    end

    test "renders formatted started_at for runs with a timestamp", %{conn: conn} do
      workflow = workflow_fixture(%{nodes: [@valid_node]})
      {:ok, run} = Workflows.create_run(workflow, @valid_source_event)
      Workflows.update_run(run, %{started_at: ~U[2024-06-01 12:30:00Z]})

      {:ok, _view, html} = live(conn, ~p"/bo/workflows/#{workflow.id}")
      assert html =~ "2024-06-01 12:30"
    end
  end

  describe "helper fallbacks" do
    test "redirects when fetch_workflow returns non-workflow response", %{conn: conn} do
      stub(Zaq.NodeRouterMock, :dispatch, fn event ->
        case event.request do
          %{function: :get_workflow!} -> %{event | response: :not_found}
          _ -> event
        end
      end)

      assert {:error, {:live_redirect, %{to: "/bo/workflows"}}} =
               live(conn, ~p"/bo/workflows/#{Ecto.UUID.generate()}")
    end

    test "shows Runs (0) when count_runs returns non-integer", %{conn: conn} do
      workflow = workflow_fixture()

      stub(Zaq.NodeRouterMock, :dispatch, fn event ->
        case event.request do
          %{function: :count_runs} -> %{event | response: :bad}
          %{module: mod, function: fun, args: args} -> %{event | response: apply(mod, fun, args)}
          _ -> event
        end
      end)

      {:ok, _view, html} = live(conn, ~p"/bo/workflows/#{workflow.id}")
      assert html =~ "Runs (0)"
    end

    test "shows Runs (0) when count_runs raises", %{conn: conn} do
      workflow = workflow_fixture()

      stub(Zaq.NodeRouterMock, :dispatch, fn event ->
        case event.request do
          %{function: :count_runs} ->
            raise "db error"

          %{module: mod, function: fun, args: args} when is_atom(mod) and is_atom(fun) ->
            %{event | response: apply(mod, fun, args)}

          _ ->
            event
        end
      end)

      {:ok, _view, html} = live(conn, ~p"/bo/workflows/#{workflow.id}")
      assert html =~ "Runs (0)"
    end

    test "shows 'None configured' when fetch_triggers returns non-list", %{conn: conn} do
      workflow = workflow_fixture()

      stub(Zaq.NodeRouterMock, :dispatch, fn event ->
        case event.request do
          %{function: :list_triggers_for_workflow} -> %{event | response: :bad}
          %{module: mod, function: fun, args: args} -> %{event | response: apply(mod, fun, args)}
          _ -> event
        end
      end)

      {:ok, _view, html} = live(conn, ~p"/bo/workflows/#{workflow.id}")
      assert html =~ "None configured"
    end

    test "shows 'None configured' when fetch_triggers raises", %{conn: conn} do
      workflow = workflow_fixture()

      stub(Zaq.NodeRouterMock, :dispatch, fn event ->
        case event.request do
          %{function: :list_triggers_for_workflow} ->
            raise "db error"

          %{module: mod, function: fun, args: args} when is_atom(mod) and is_atom(fun) ->
            %{event | response: apply(mod, fun, args)}

          _ ->
            event
        end
      end)

      {:ok, _view, html} = live(conn, ~p"/bo/workflows/#{workflow.id}")
      assert html =~ "None configured"
    end

    test "shows 'No runs yet' when fetch_runs returns non-list", %{conn: conn} do
      workflow = workflow_fixture()

      stub(Zaq.NodeRouterMock, :dispatch, fn event ->
        case event.request do
          %{function: :list_runs} -> %{event | response: :bad}
          %{module: mod, function: fun, args: args} -> %{event | response: apply(mod, fun, args)}
          _ -> event
        end
      end)

      {:ok, _view, html} = live(conn, ~p"/bo/workflows/#{workflow.id}")
      assert html =~ "No runs yet."
    end

    test "shows 'No runs yet' when fetch_runs raises", %{conn: conn} do
      workflow = workflow_fixture()

      stub(Zaq.NodeRouterMock, :dispatch, fn event ->
        case event.request do
          %{function: :list_runs} ->
            raise "db error"

          %{module: mod, function: fun, args: args} when is_atom(mod) and is_atom(fun) ->
            %{event | response: apply(mod, fun, args)}

          _ ->
            event
        end
      end)

      {:ok, _view, html} = live(conn, ~p"/bo/workflows/#{workflow.id}")
      assert html =~ "No runs yet."
    end
  end
end
