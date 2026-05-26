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
      |> form("form[phx-submit='create_trigger']", %{"trigger" => %{"enabled" => "true"}})
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

    test "creates cron trigger and shows it in list", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/bo/triggers")
      lv |> element("button", "+ New Trigger") |> render_click()

      # Switch form to cron mode — cron section renders with "Every 5 min" default preset
      lv
      |> form("form[phx-submit='create_trigger']")
      |> render_change(%{
        "trigger" => %{"trigger_type" => "cron", "event_name" => "cron.daily_sync"}
      })

      # Submit using the default preset (hidden input carries "*/5 * * * *" from DOM)
      lv
      |> form("form[phx-submit='create_trigger']", %{
        "trigger" => %{
          "trigger_type" => "cron",
          "event_name" => "cron.daily_sync",
          "cron_preset" => "*/5 * * * *",
          "enabled" => "true"
        }
      })
      |> render_submit()

      html = render(lv)
      assert html =~ "cron.daily_sync"

      [trigger] = Workflows.list_triggers()
      assert trigger.trigger_type == "cron"
      assert trigger.cron_schedule == "*/5 * * * *"
    end

    test "cron trigger requires event name", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/bo/triggers")
      lv |> element("button", "+ New Trigger") |> render_click()

      # Switch to cron mode with blank event_name
      lv
      |> form("form[phx-submit='create_trigger']")
      |> render_change(%{"trigger" => %{"trigger_type" => "cron", "event_name" => ""}})

      # Submit without event_name — changeset should reject
      lv
      |> form("form[phx-submit='create_trigger']", %{
        "trigger" => %{
          "trigger_type" => "cron",
          "event_name" => "",
          "cron_preset" => "*/5 * * * *",
          "enabled" => "true"
        }
      })
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
      |> form("form[phx-submit='update_trigger']", %{"trigger" => %{"enabled" => "true"}})
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

  # --- validate event ---

  describe "validate event" do
    test "re-renders form changeset on phx-change", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/bo/triggers")
      lv |> element("button", "+ New Trigger") |> render_click()

      html =
        lv
        |> form("form[phx-submit='create_trigger']")
        |> render_change(%{"trigger" => %{"enabled" => "true"}})

      assert html =~ "New Trigger"
    end
  end

  # --- create trigger failures ---

  describe "create trigger failure" do
    test "create trigger submit stays responsive on stubbed dispatch", %{conn: conn} do
      stub(Zaq.NodeRouterMock, :dispatch, fn event ->
        case Keyword.get(event.opts, :action) do
          :trigger ->
            case Map.get(event.request, :action) do
              "create" -> %{event | response: :error}
              _ -> Api.handle_event(event, :trigger, nil)
            end

          _ ->
            case event.request do
              %{module: mod, function: fun, args: args} when is_atom(mod) and is_atom(fun) ->
                %{event | response: apply(mod, fun, args)}

              _ ->
                event
            end
        end
      end)

      {:ok, lv, _html} = live(conn, ~p"/bo/triggers")
      lv |> element("button", "+ New Trigger") |> render_click()
      render_click(lv, "set_event_name", %{"name" => "generic.fail"})

      html =
        lv
        |> form("form[phx-submit='create_trigger']", %{
          "trigger" => %{"event_name" => "generic.fail", "enabled" => "true"}
        })
        |> render_submit()

      assert html =~ "Triggers"
    end
  end

  # --- update trigger failures ---

  describe "update trigger failure" do
    test "update trigger submit stays responsive on stubbed dispatch", %{conn: conn} do
      t = create_trigger("update.fail.evt")

      stub(Zaq.NodeRouterMock, :dispatch, fn event ->
        case Keyword.get(event.opts, :action) do
          :trigger ->
            case Map.get(event.request, :action) do
              "update" -> %{event | response: :error}
              _ -> Api.handle_event(event, :trigger, nil)
            end

          _ ->
            case event.request do
              %{module: mod, function: fun, args: args} when is_atom(mod) and is_atom(fun) ->
                %{event | response: apply(mod, fun, args)}

              _ ->
                event
            end
        end
      end)

      {:ok, lv, _html} = live(conn, ~p"/bo/triggers")

      lv
      |> element("button[phx-click='open_edit'][phx-value-trigger_id='#{t.id}']")
      |> render_click()

      render_click(lv, "set_event_name", %{"name" => "new.fail.name"})

      html =
        lv
        |> form("form[phx-submit='update_trigger']", %{
          "trigger" => %{"event_name" => "new.fail.name", "enabled" => "true"}
        })
        |> render_submit()

      assert html =~ "Triggers"
    end
  end

  # --- assign modal workflow description ---

  describe "assign modal workflow description" do
    test "shows workflow description in assign modal when present", %{conn: conn} do
      {:ok, _wf} =
        Workflows.create_workflow(%{
          name: "Desc Workflow",
          description: "A workflow about things",
          status: "draft",
          nodes: [@valid_node],
          edges: []
        })

      t = create_trigger("assign.desc.evt")
      {:ok, lv, _html} = live(conn, ~p"/bo/triggers")

      lv
      |> element("button[phx-click='open_assign'][phx-value-trigger_id='#{t.id}']")
      |> render_click()

      assert render(lv) =~ "A workflow about things"
    end
  end

  # --- find_trigger fallback ---

  describe "find_trigger fallback" do
    test "falls back to DB lookup and updates when trigger not in assigns", %{conn: conn} do
      t = create_trigger("fallback.find.evt")

      stub(Zaq.NodeRouterMock, :dispatch, fn event ->
        case Keyword.get(event.opts, :action) do
          :trigger ->
            case Map.get(event.request, :action) do
              "list_with_runs" -> %{event | response: []}
              _ -> Api.handle_event(event, :trigger, nil)
            end

          _ ->
            case event.request do
              %{module: mod, function: fun, args: args} when is_atom(mod) and is_atom(fun) ->
                %{event | response: apply(mod, fun, args)}

              _ ->
                event
            end
        end
      end)

      {:ok, lv, _html} = live(conn, ~p"/bo/triggers")

      html =
        render_click(lv, "update_trigger", %{
          "trigger" => %{"event_name" => "fallback.find.evt", "enabled" => "true"},
          "trigger_id" => t.id
        })

      assert html =~ "Triggers"
    end
  end

  # --- atomize rescue ---

  describe "atomize rescue" do
    test "falls back to raw params when a key is not an existing atom", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/bo/triggers")
      lv |> element("button", "+ New Trigger") |> render_click()

      unknown_key = "totally_unknown_key_#{System.unique_integer()}"

      html =
        lv
        |> form("form[phx-submit='create_trigger']")
        |> render_change(%{"trigger" => %{unknown_key => "value"}})

      assert html =~ "New Trigger"
    end
  end
end
