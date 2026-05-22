defmodule ZaqWeb.Live.BO.AI.TriggersLiveTest do
  use ZaqWeb.ConnCase, async: false

  import Mox
  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures

  alias Zaq.Accounts
  alias Zaq.Engine.{Api, Workflows}

  setup :verify_on_exit!

  @valid_node %{
    name: "step",
    type: "action",
    module: "Zaq.Agent.Tools.Email.FetchEmails",
    params: %{},
    index: 0
  }

  setup %{conn: conn} do
    user = user_fixture(%{username: "triggers-test-#{System.unique_integer([:positive])}"})
    {:ok, user} = Accounts.change_password(user, %{password: "StrongPass1!"})
    stub(Zaq.NodeRouterMock, :find_node, fn _supervisor -> :services@localhost end)

    stub(Zaq.NodeRouterMock, :dispatch, fn event ->
      case Keyword.get(event.opts, :action) do
        :trigger ->
          Api.handle_event(event, :trigger, nil)

        _ ->
          case event.request do
            %{module: mod, function: fun, args: args} when is_atom(mod) and is_atom(fun) ->
              %{event | response: apply(mod, fun, args)}

            _ ->
              event
          end
      end
    end)

    conn = init_test_session(conn, %{user_id: user.id})
    %{conn: conn}
  end

  defp create_workflow(name) do
    {:ok, w} =
      Workflows.create_workflow(%{
        name: name,
        status: "draft",
        nodes: [@valid_node],
        edges: []
      })

    w
  end

  defp create_trigger(event_name) do
    {:ok, t} = Workflows.create_trigger(%{event_name: event_name})
    t
  end

  # --- mount ---

  describe "mount" do
    test "renders 200", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/bo/triggers")
      assert html =~ "Triggers"
    end

    test "shows empty state when no triggers", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/bo/triggers")
      assert html =~ "No triggers yet"
    end

    test "shows triggers when they exist", %{conn: conn} do
      create_trigger("email.received")
      create_trigger("webhook.posted")
      {:ok, _lv, html} = live(conn, ~p"/bo/triggers")
      assert html =~ "email.received"
      assert html =~ "webhook.posted"
    end

    test "sidebar link to triggers is present", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/bo/triggers")
      assert html =~ ~p"/bo/triggers"
    end
  end

  # --- create ---

  describe "create trigger" do
    test "opens create modal", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/bo/triggers")
      lv |> element("button", "+ New Trigger") |> render_click()
      assert render(lv) =~ "New Trigger"
    end

    test "creates trigger and shows it in list", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/bo/triggers")
      lv |> element("button", "+ New Trigger") |> render_click()
      render_click(lv, "set_event_name", %{"name" => "email.new"})

      lv
      |> form("form[phx-submit='create_trigger']", %{"trigger" => %{"enabled" => "on"}})
      |> render_submit()

      html = render(lv)
      assert html =~ "email.new"
    end

    test "shows error when event_name is blank", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/bo/triggers")
      lv |> element("button", "+ New Trigger") |> render_click()

      lv
      |> form("form[phx-submit='create_trigger']", %{"trigger" => %{}})
      |> render_submit()

      assert Workflows.list_triggers() == []
    end

    test "cancel closes modal without creating", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/bo/triggers")
      lv |> element("button", "+ New Trigger") |> render_click()
      lv |> element("button", "Cancel") |> render_click()

      refute render(lv) =~ ~s(phx-submit="create_trigger")
      assert Workflows.list_triggers() == []
    end
  end

  # --- edit ---

  describe "edit trigger" do
    test "opens edit modal pre-populated", %{conn: conn} do
      t = create_trigger("edit.me")
      {:ok, lv, _html} = live(conn, ~p"/bo/triggers")

      lv
      |> element("button[phx-click='open_edit'][phx-value-trigger_id='#{t.id}']")
      |> render_click()

      html = render(lv)
      assert html =~ "Edit Trigger"
      assert html =~ "edit.me"
    end

    test "updates trigger event_name", %{conn: conn} do
      t = create_trigger("old.name")
      {:ok, lv, _html} = live(conn, ~p"/bo/triggers")

      lv
      |> element("button[phx-click='open_edit'][phx-value-trigger_id='#{t.id}']")
      |> render_click()

      render_click(lv, "set_event_name", %{"name" => "new.name"})

      lv
      |> form("form[phx-submit='update_trigger']", %{"trigger" => %{"enabled" => "on"}})
      |> render_submit()

      html = render(lv)
      assert html =~ "new.name"
    end
  end

  # --- toggle enabled ---

  describe "toggle_enabled" do
    test "flips enabled state", %{conn: conn} do
      t = create_trigger("toggle.me")
      {:ok, lv, _html} = live(conn, ~p"/bo/triggers")

      lv
      |> element("button[phx-click='toggle_enabled'][phx-value-trigger_id='#{t.id}']")
      |> render_click()

      updated = Workflows.get_trigger!(t.id)
      assert updated.enabled == false
    end
  end

  # --- delete ---

  describe "delete trigger" do
    test "deletes trigger after confirmation", %{conn: conn} do
      t = create_trigger("delete.me")
      {:ok, lv, _html} = live(conn, ~p"/bo/triggers")

      lv
      |> element("button[phx-click='open_delete'][phx-value-trigger_id='#{t.id}']")
      |> render_click()

      lv
      |> element("button[phx-click='confirm_delete']")
      |> render_click()

      refute render(lv) =~ "delete.me"
      assert Workflows.list_triggers() == []
    end

    test "cancel keeps trigger in list", %{conn: conn} do
      t = create_trigger("keep.me")
      {:ok, lv, _html} = live(conn, ~p"/bo/triggers")

      lv
      |> element("button[phx-click='open_delete'][phx-value-trigger_id='#{t.id}']")
      |> render_click()

      lv |> element("button", "Cancel") |> render_click()

      assert render(lv) =~ "keep.me"
      assert length(Workflows.list_triggers()) == 1
    end
  end

  # --- workflow assignment ---

  describe "workflow assignment" do
    test "assigns workflow to trigger and shows chip", %{conn: conn} do
      t = create_trigger("assign.evt")
      w = create_workflow("WF-Assign")
      {:ok, lv, _html} = live(conn, ~p"/bo/triggers")

      lv
      |> element("button[phx-click='open_assign'][phx-value-trigger_id='#{t.id}']")
      |> render_click()

      lv
      |> element("button[phx-click='assign_workflow'][phx-value-workflow_id='#{w.id}']")
      |> render_click()

      html = render(lv)
      assert html =~ "WF-Assign"
    end

    test "removes workflow chip after removal", %{conn: conn} do
      t = create_trigger("remove.evt")
      w = create_workflow("WF-Remove")
      Workflows.assign_workflow_to_trigger(t, w)

      {:ok, lv, html} = live(conn, ~p"/bo/triggers")
      assert html =~ "WF-Remove"

      lv
      |> element(
        "button[phx-click='remove_workflow'][phx-value-trigger_id='#{t.id}'][phx-value-workflow_id='#{w.id}']"
      )
      |> render_click()

      refute render(lv) =~ "WF-Remove"
    end
  end

  # --- recent runs ---

  describe "recent runs" do
    test "run row links to correct run path", %{conn: conn} do
      t = create_trigger("run.evt")
      w = create_workflow("WF-Runs")
      Workflows.assign_workflow_to_trigger(t, w)

      source_event = %Zaq.Event{
        request: nil,
        next_hop: nil,
        trace_id: Ecto.UUID.generate(),
        assigns: %{trigger_type: :event, input: %{}}
      }

      {:ok, run} = Workflows.create_run(w, source_event)

      {:ok, _lv, html} = live(conn, ~p"/bo/triggers")
      assert html =~ "/bo/workflows/#{w.id}/runs/#{run.id}"
    end
  end
end
