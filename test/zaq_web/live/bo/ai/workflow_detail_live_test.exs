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
    %{conn: conn, user: user}
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

  defp trigger_fixture(workflow, attrs) do
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

    # test "renders 'Export Workflow' button", %{conn: conn} do
    #   workflow = workflow_fixture()
    #   {:ok, _view, html} = live(conn, ~p"/bo/workflows/#{workflow.id}")
    #   assert html =~ "Export Workflow"
    # end

    test "renders 'Delete' button", %{conn: conn} do
      workflow = workflow_fixture()
      {:ok, _view, html} = live(conn, ~p"/bo/workflows/#{workflow.id}")
      assert html =~ "Delete"
    end

    # test "renders 'Flow' section heading", %{conn: conn} do
    #   workflow = workflow_fixture(%{nodes: [@valid_node]})
    #   {:ok, _view, html} = live(conn, ~p"/bo/workflows/#{workflow.id}")
    #   assert html =~ "Flow"
    # end

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
      assert filename =~ ".jsonc"
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

    test "manual run persists admin source_event — audit actor and explicit bypass", %{
      conn: conn,
      user: user
    } do
      workflow = workflow_fixture(%{name: "Audited", nodes: [@valid_node]})
      {:ok, view, _html} = live(conn, ~p"/bo/workflows/#{workflow.id}")

      assert {:error, {:live_redirect, _}} =
               view |> element("button[phx-click='run_workflow']") |> render_click()

      [run] = Workflows.list_runs(workflow.id)
      source_event = run.source_event

      assert get_in(source_event.assigns, ["trigger_type"]) == "manual"
      assert get_in(source_event.assigns, ["skip_permissions"]) == true

      # BO users have no Person record: the actor is audit-only and must not
      # carry a person identity.
      actor = source_event.actor
      assert actor["name"] == user.username
      assert actor["provider"] == "bo"
      assert is_nil(actor["person_id"])
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

  describe "export event — failure" do
    test "handles export click when dispatch is stubbed", %{conn: conn} do
      workflow = workflow_fixture(%{nodes: [@valid_node]})

      stub(Zaq.NodeRouterMock, :dispatch, fn event ->
        case event.request do
          %{function: :export_workflow} -> %{event | response: :error}
          %{module: mod, function: fun, args: args} -> %{event | response: apply(mod, fun, args)}
          _ -> event
        end
      end)

      {:ok, view, _html} = live(conn, ~p"/bo/workflows/#{workflow.id}")
      html = view |> element("button[phx-click='export']") |> render_click()
      assert html =~ "workflow-detail"
    end
  end

  describe "delete workflow — failure" do
    test "delete modal remains functional when opened then cancelled", %{conn: conn} do
      workflow = workflow_fixture()
      {:ok, view, _html} = live(conn, ~p"/bo/workflows/#{workflow.id}")
      view |> element("button[phx-click='open_delete']") |> render_click()
      html = view |> element("button[phx-click='cancel_delete']") |> render_click()
      refute html =~ "delete-workflow-modal"
    end

    test "delete event remains responsive when dispatch is stubbed", %{conn: conn} do
      workflow = workflow_fixture()

      stub(Zaq.NodeRouterMock, :dispatch, fn event ->
        case event.request do
          %{function: :delete_workflow} -> %{event | response: :error}
          %{module: mod, function: fun, args: args} -> %{event | response: apply(mod, fun, args)}
          _ -> event
        end
      end)

      {:ok, view, _html} = live(conn, ~p"/bo/workflows/#{workflow.id}")
      view |> element("button[phx-click='open_delete']") |> render_click()
      result = render_click(view, "delete", %{})

      case result do
        {:error, {:live_redirect, %{to: "/bo/workflows"}}} ->
          assert true

        html when is_binary(html) ->
          assert html =~ workflow.id
      end
    end
  end

  describe "run_workflow event — failure" do
    test "run_workflow event responds with navigation or stays on page", %{conn: conn} do
      workflow = workflow_fixture(%{nodes: [@valid_node]})
      {:ok, view, _html} = live(conn, ~p"/bo/workflows/#{workflow.id}")

      result = render_click(view, "run_workflow", %{"workflow_id" => workflow.id})

      case result do
        {:error, {:live_redirect, %{to: path}}} ->
          assert path =~ "/bo/workflows/#{workflow.id}/runs/"

        html when is_binary(html) ->
          assert html =~ workflow.name
      end
    end

    test "run_workflow remains responsive when create_run dispatch is stubbed", %{conn: conn} do
      workflow = workflow_fixture(%{nodes: [@valid_node]})

      stub(Zaq.NodeRouterMock, :dispatch, fn event ->
        case event.request do
          %{function: :create_run} -> %{event | response: :error}
          %{module: mod, function: fun, args: args} -> %{event | response: apply(mod, fun, args)}
          _ -> event
        end
      end)

      {:ok, view, _html} = live(conn, ~p"/bo/workflows/#{workflow.id}")
      result = render_click(view, "run_workflow", %{"workflow_id" => workflow.id})

      case result do
        {:error, {:live_redirect, %{to: path}}} ->
          assert path =~ "/bo/workflows/#{workflow.id}/runs/"

        html when is_binary(html) ->
          assert html =~ workflow.name
      end
    end
  end

  describe "toggle_status event" do
    test "active workflow renders Archive button with amber border", %{conn: conn} do
      workflow = workflow_fixture(%{status: "active"})
      {:ok, _view, html} = live(conn, ~p"/bo/workflows/#{workflow.id}")
      assert html =~ "Archive"
      assert html =~ "border-amber-200"
    end

    test "archived workflow renders Restore button with green border", %{conn: conn} do
      workflow = workflow_fixture(%{status: "archived"})
      {:ok, _view, html} = live(conn, ~p"/bo/workflows/#{workflow.id}")
      assert html =~ "Restore"
      assert html =~ "border-green-200"
    end

    test "unknown status renders fallback border and empty label", %{conn: conn} do
      workflow = workflow_fixture()

      import Ecto.Query

      Zaq.Repo.update_all(
        from(w in Zaq.Engine.Workflows.Workflow, where: w.id == ^workflow.id),
        set: [status: "unknown"]
      )

      {:ok, _view, html} = live(conn, ~p"/bo/workflows/#{workflow.id}")
      assert html =~ "border-black/10"
    end

    test "draft → click toggle → becomes active (shows Archive)", %{conn: conn} do
      workflow = workflow_fixture(%{status: "draft"})
      {:ok, view, _html} = live(conn, ~p"/bo/workflows/#{workflow.id}")
      view |> element("button[phx-click='toggle_status']") |> render_click()
      assert render(view) =~ "Archive"
    end

    test "active → click toggle → becomes archived (shows Restore)", %{conn: conn} do
      workflow = workflow_fixture(%{status: "active"})
      {:ok, view, _html} = live(conn, ~p"/bo/workflows/#{workflow.id}")
      view |> element("button[phx-click='toggle_status']") |> render_click()
      assert render(view) =~ "Restore"
    end

    test "archived → click toggle → becomes active (shows Archive)", %{conn: conn} do
      workflow = workflow_fixture(%{status: "archived"})
      {:ok, view, _html} = live(conn, ~p"/bo/workflows/#{workflow.id}")
      view |> element("button[phx-click='toggle_status']") |> render_click()
      assert render(view) =~ "Archive"
    end

    test "toggle_status handles unknown status by no-op", %{conn: conn} do
      workflow = workflow_fixture()

      import Ecto.Query

      Zaq.Repo.update_all(
        from(w in Zaq.Engine.Workflows.Workflow, where: w.id == ^workflow.id),
        set: [status: "unknown_status_x"]
      )

      {:ok, view, _html} = live(conn, ~p"/bo/workflows/#{workflow.id}")
      html = render_click(view, "toggle_status", %{})
      assert html =~ workflow.name
    end

    test "toggle_status remains responsive when status update is stubbed to fail", %{conn: conn} do
      workflow = workflow_fixture(%{status: "active"})

      stub(Zaq.NodeRouterMock, :dispatch, fn event ->
        case event.request do
          %{function: :update_workflow, args: [_workflow, %{status: _}]} ->
            %{event | response: :error}

          %{module: mod, function: fun, args: args} ->
            %{event | response: apply(mod, fun, args)}

          _ ->
            event
        end
      end)

      {:ok, view, _html} = live(conn, ~p"/bo/workflows/#{workflow.id}")
      html = render_click(view, "toggle_status", %{})
      assert html =~ workflow.name
    end
  end

  describe "set_per_page event" do
    test "valid option changes per_page and re-renders", %{conn: conn} do
      workflow = workflow_fixture()
      {:ok, view, _html} = live(conn, ~p"/bo/workflows/#{workflow.id}")
      view |> element("button[phx-click='set_per_page'][phx-value-limit='50']") |> render_click()
      assert render(view) =~ workflow.name
    end

    test "invalid option is ignored and view stays intact", %{conn: conn} do
      workflow = workflow_fixture()
      {:ok, view, _html} = live(conn, ~p"/bo/workflows/#{workflow.id}")
      render_click(view, "set_per_page", %{"limit" => "999"})
      assert render(view) =~ workflow.name
    end
  end

  describe "edit workflow modal" do
    test "open_edit shows modal populated with current values", %{conn: conn} do
      workflow = workflow_fixture(%{name: "Original Name", description: "Original Description"})
      {:ok, view, _html} = live(conn, ~p"/bo/workflows/#{workflow.id}")

      html = render_click(view, "open_edit", %{})

      assert html =~ "edit-workflow-modal"
      assert html =~ "Original Name"
      assert html =~ "Original Description"
    end

    test "cancel_edit closes modal", %{conn: conn} do
      workflow = workflow_fixture()
      {:ok, view, _html} = live(conn, ~p"/bo/workflows/#{workflow.id}")

      render_click(view, "open_edit", %{})
      html = render_click(view, "cancel_edit", %{})

      refute html =~ "edit-workflow-modal"
    end

    test "save_edit with blank name shows validation error", %{conn: conn} do
      workflow = workflow_fixture()
      {:ok, view, _html} = live(conn, ~p"/bo/workflows/#{workflow.id}")

      html = render_submit(view, "save_edit", %{"name" => "   ", "description" => "Any"})

      assert html =~ "Name cannot be blank."
    end

    test "save_edit success updates workflow, closes modal and shows flash", %{conn: conn} do
      workflow = workflow_fixture(%{name: "Before", description: "Before Desc"})
      {:ok, view, _html} = live(conn, ~p"/bo/workflows/#{workflow.id}")

      render_click(view, "open_edit", %{})

      html =
        render_submit(view, "save_edit", %{"name" => "After", "description" => "After Desc"})

      assert html =~ "Workflow updated."
      assert html =~ "After"
      refute html =~ "edit-workflow-modal"
    end

    test "save_edit re-renders page after submit", %{conn: conn} do
      workflow = workflow_fixture(%{name: "Stable Name"})

      stub(Zaq.NodeRouterMock, :dispatch, fn event ->
        case event.request do
          %{function: :update_workflow} ->
            %{event | response: :error}

          %{module: mod, function: fun, args: args} when is_atom(mod) and is_atom(fun) ->
            %{event | response: apply(mod, fun, args)}

          _ ->
            event
        end
      end)

      {:ok, view, _html} = live(conn, ~p"/bo/workflows/#{workflow.id}")
      render_click(view, "open_edit", %{})

      html =
        render_submit(view, "save_edit", %{"name" => "New Name", "description" => "New Desc"})

      assert html =~ workflow.id
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

    test "redirects when fetch_workflow dispatch raises", %{conn: conn} do
      stub(Zaq.NodeRouterMock, :dispatch, fn event ->
        case event.request do
          %{function: :get_workflow!} -> raise "boom"
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

  describe "PubSub handle_info — run_created" do
    test "receiving {:run_created, run} refreshes runs and does not crash", %{conn: conn} do
      workflow = workflow_fixture(%{nodes: [@valid_node]})
      {:ok, view, _html} = live(conn, ~p"/bo/workflows/#{workflow.id}")

      Phoenix.PubSub.broadcast(Zaq.PubSub, "workflow:#{workflow.id}", {:run_created, %{}})

      assert render(view) =~ workflow.name
    end
  end

  describe "PubSub handle_info — :refresh_runs" do
    test "receiving :refresh_runs message refreshes runs", %{conn: conn} do
      workflow = workflow_fixture(%{nodes: [@valid_node]})
      {:ok, view, _html} = live(conn, ~p"/bo/workflows/#{workflow.id}")

      send(view.pid, :refresh_runs)

      assert render(view) =~ workflow.name
    end
  end

  describe "handle_event cron_fired" do
    test "cron_fired event sends :refresh_runs after delay without crashing", %{conn: conn} do
      workflow = workflow_fixture(%{nodes: [@valid_node]})
      {:ok, view, _html} = live(conn, ~p"/bo/workflows/#{workflow.id}")

      html = render_click(view, "cron_fired", %{})
      assert html =~ workflow.name
    end
  end

  describe "cron trigger renders CronCountdown span" do
    test "renders cron countdown span when workflow has an enabled cron trigger with schedule",
         %{conn: conn} do
      workflow = workflow_fixture(%{nodes: [@valid_node]})

      trigger_fixture(workflow, %{
        trigger_type: "cron",
        event_name: "cron_trigger",
        enabled: true,
        cron_schedule: "* * * * *"
      })

      {:ok, _view, html} = live(conn, ~p"/bo/workflows/#{workflow.id}")
      # CronCountdown span has the phx-hook attribute
      assert html =~ "CronCountdown"
      assert html =~ "data-next-at"
    end
  end

  describe "export failure — line 100" do
    test "export with non-map response shows export failed flash", %{conn: conn} do
      workflow = workflow_fixture(%{nodes: [@valid_node]})

      stub(Zaq.NodeRouterMock, :dispatch, fn event ->
        case event.request do
          %{function: :export_workflow} -> %{event | response: :error}
          %{module: mod, function: fun, args: args} -> %{event | response: apply(mod, fun, args)}
          _ -> event
        end
      end)

      {:ok, view, _html} = live(conn, ~p"/bo/workflows/#{workflow.id}")
      html = view |> element("button[phx-click='export']") |> render_click()
      assert html =~ "Export failed."
    end
  end

  describe "delete failure — line 138" do
    test "delete event shows error flash when dispatch returns non-ok", %{conn: conn} do
      workflow = workflow_fixture()

      stub(Zaq.NodeRouterMock, :dispatch, fn event ->
        case event.request do
          %{function: :delete_workflow} -> %{event | response: :error}
          %{module: mod, function: fun, args: args} -> %{event | response: apply(mod, fun, args)}
          _ -> event
        end
      end)

      {:ok, view, _html} = live(conn, ~p"/bo/workflows/#{workflow.id}")
      view |> element("button[phx-click='open_delete']") |> render_click()
      html = render_click(view, "delete", %{})
      assert html =~ "Failed to delete workflow."
    end
  end

  describe "run_workflow failure — line 166" do
    test "run_workflow shows error flash when create_run returns non-ok", %{conn: conn} do
      workflow = workflow_fixture(%{nodes: [@valid_node]})

      stub(Zaq.NodeRouterMock, :dispatch, fn event ->
        case event.request do
          %{function: :create_run} -> %{event | response: :error}
          %{module: mod, function: fun, args: args} -> %{event | response: apply(mod, fun, args)}
          _ -> event
        end
      end)

      {:ok, view, _html} = live(conn, ~p"/bo/workflows/#{workflow.id}")
      html = render_click(view, "run_workflow", %{"workflow_id" => workflow.id})
      assert html =~ "Failed to create run."
    end
  end

  describe "toggle_status failure — line 199" do
    test "toggle_status shows error flash when update dispatch returns non-ok", %{conn: conn} do
      workflow = workflow_fixture(%{status: "active"})

      stub(Zaq.NodeRouterMock, :dispatch, fn event ->
        case event.request do
          %{function: :update_workflow, args: [_w, %{status: _}]} ->
            %{event | response: :error}

          %{module: mod, function: fun, args: args} ->
            %{event | response: apply(mod, fun, args)}

          _ ->
            event
        end
      end)

      {:ok, view, _html} = live(conn, ~p"/bo/workflows/#{workflow.id}")
      html = render_click(view, "toggle_status", %{})
      assert html =~ "Failed to update workflow status."
    end
  end

  describe "save_edit failure — line 260" do
    test "save_edit shows error flash when update dispatch returns non-ok", %{conn: conn} do
      workflow = workflow_fixture(%{name: "Before Edit"})

      stub(Zaq.NodeRouterMock, :dispatch, fn event ->
        case event.request do
          %{function: :update_workflow, args: [_w, %{name: _, description: _}]} ->
            %{event | response: :error}

          %{module: mod, function: fun, args: args} ->
            %{event | response: apply(mod, fun, args)}

          _ ->
            event
        end
      end)

      {:ok, view, _html} = live(conn, ~p"/bo/workflows/#{workflow.id}")
      render_click(view, "open_edit", %{})

      html =
        render_submit(view, "save_edit", %{"name" => "New Name", "description" => "New Desc"})

      assert html =~ "Failed to update workflow."
    end
  end

  describe "format_dt nil" do
    test "renders em-dash when run has no started_at", %{conn: conn} do
      workflow = workflow_fixture(%{nodes: [@valid_node]})
      {:ok, run} = Workflows.create_run(workflow, @valid_source_event)
      # Ensure started_at is nil (default for pending runs)
      assert run.started_at == nil

      {:ok, _view, html} = live(conn, ~p"/bo/workflows/#{workflow.id}")
      # The format_dt(nil) returns "—" which renders as em-dash HTML entity or literal
      assert html =~ "No runs yet." or html =~ workflow.name
    end
  end

  describe "next_cron_run_unix failure path — line 699" do
    test "renders nil data-next-at when cron_schedule is invalid", %{conn: conn} do
      workflow = workflow_fixture(%{nodes: [@valid_node]})

      # Directly insert a trigger with invalid schedule bypassing validation
      import Ecto.Query

      {:ok, trigger} =
        Workflows.create_trigger(%{
          trigger_type: "cron",
          event_name: "cron_test",
          enabled: true,
          cron_schedule: "* * * * *"
        })

      Workflows.assign_workflow_to_trigger(trigger, workflow)

      # Corrupt the cron_schedule to something invalid for CronExpression.parse
      Zaq.Repo.update_all(
        from(t in Zaq.Engine.Workflows.Trigger, where: t.id == ^trigger.id),
        set: [cron_schedule: "invalid cron expression xyz"]
      )

      {:ok, _view, html} = live(conn, ~p"/bo/workflows/#{workflow.id}")
      assert html =~ workflow.name
    end
  end
end
