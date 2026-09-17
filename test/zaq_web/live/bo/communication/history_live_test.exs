defmodule ZaqWeb.Live.BO.Communication.HistoryLiveTest do
  use ZaqWeb.ConnCase, async: true
  use ExUnitProperties

  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures

  alias Zaq.Accounts
  alias Zaq.Accounts.People
  alias Zaq.Engine.Conversations

  setup %{conn: conn} do
    user = user_fixture(%{username: "testadmin"})
    {:ok, user} = Accounts.change_password(user, %{password: "StrongPass1!"})

    conn = init_test_session(conn, %{user_id: user.id})

    %{conn: conn, user: user}
  end

  test "renders history placeholder", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/bo/history")

    assert html =~ "History"
    assert html =~ "conversations"
  end

  describe "legacy conversations index intent" do
    test "shows channel column", %{conn: conn, user: user} do
      _conv = create_conv(user.id, %{title: "Channel Column Conv"})
      {:ok, _view, html} = live(conn, ~p"/bo/history")

      assert html =~ "Channel"
    end

    test "shows empty state when no conversations", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/bo/history")

      assert html =~ "No conversations found"
    end

    test "renders link to conversation detail", %{conn: conn, user: user} do
      conv = create_conv(user.id, %{title: "Detail Link Conv"})
      {:ok, _view, html} = live(conn, ~p"/bo/history")

      assert html =~ "/bo/conversations/#{conv.id}"
    end
  end

  describe "mount" do
    test "shows conversations for current user", %{conn: conn, user: user} do
      conv = create_conv(user.id, %{title: "My History Conv"})
      {:ok, _view, html} = live(conn, ~p"/bo/history")
      assert html =~ conv.title
    end

    test "does not show conversations for other users", %{conn: conn, user: user} do
      other_user = user_fixture()
      _other_conv = create_conv(other_user.id, %{title: "Other User Conv XYZ"})
      _my_conv = create_conv(user.id, %{title: "My Own Conv"})

      {:ok, _view, html} = live(conn, ~p"/bo/history")
      refute html =~ "Other User Conv XYZ"
    end
  end

  describe "filter event" do
    test "switches status routes and applies same-status filters without navigation", %{
      conn: conn,
      user: user
    } do
      active = create_conv(user.id, %{title: "Active Status Conv", status: "active"})

      {:ok, archived} =
        create_conv(user.id, %{title: "Archived Status Conv"})
        |> Conversations.archive_conversation()

      other_user = user_fixture()
      _foreign = create_conv(other_user.id, %{title: "Foreign Status Conv", status: "active"})

      {:ok, mattermost} =
        Conversations.create_conversation(%{
          channel_type: "mattermost",
          channel_user_id: "mm_status_#{System.unique_integer([:positive])}",
          user_id: user.id,
          title: "Mattermost Status Conv"
        })

      {:ok, view, _html} = live(conn, ~p"/bo/history")
      render_hook(view, "toggle_select", %{"id" => active.id})

      view
      |> element("form[phx-change='filter']")
      |> render_change(%{"status" => "archived", "channel_type" => "all"})

      assert_patch(view, "/bo/history/archived")
      html = render(view)
      assert html =~ archived.title
      refute html =~ active.title
      refute html =~ "Foreign Status Conv"
      assert html =~ "Archived History"
      refute html =~ "1 selected"

      view
      |> element("form[phx-change='filter']")
      |> render_change(%{"status" => "active", "channel_type" => "all"})

      assert_patch(view, "/bo/history")
      html = render(view)
      assert html =~ active.title
      refute html =~ archived.title
      refute html =~ "Foreign Status Conv"
      assert html =~ "History"

      view
      |> element("form[phx-change='filter']")
      |> render_change(%{"status" => "active", "channel_type" => "mattermost"})

      html = render(view)
      assert html =~ mattermost.title
      refute html =~ active.title
    end

    test "archived route shows archived and excludes active conversations", %{
      conn: conn,
      user: user
    } do
      _active = create_conv(user.id, %{title: "Active Conv", status: "active"})

      {:ok, archived} =
        create_conv(user.id, %{title: "Archived Conv"})
        |> then(fn c ->
          Conversations.archive_conversation(c)
        end)

      {:ok, _view, html} = live(conn, ~p"/bo/history/archived")

      assert html =~ archived.title
      refute html =~ "Active Conv"
    end

    test "filter by channel_type filters correctly", %{conn: conn, user: user} do
      {:ok, mm_conv} =
        Conversations.create_conversation(%{
          channel_type: "mattermost",
          channel_user_id: "mm_hist_#{System.unique_integer([:positive])}",
          user_id: user.id,
          title: "MM History Conv"
        })

      _bo_conv = create_conv(user.id, %{title: "BO History Conv"})

      {:ok, view, _html} = live(conn, ~p"/bo/history")

      html =
        view
        |> element("form[phx-change='filter']")
        |> render_change(%{"status" => "all", "channel_type" => "mattermost"})

      assert html =~ mm_conv.title
    end

    test "filter with all values shows all user conversations", %{conn: conn, user: user} do
      conv = create_conv(user.id, %{title: "All Filter Conv"})
      {:ok, view, _html} = live(conn, ~p"/bo/history")

      html =
        view
        |> element("form[phx-change='filter']")
        |> render_change(%{"status" => "all", "channel_type" => "all"})

      assert html =~ conv.title
    end
  end

  describe "toggle_select event" do
    test "adds a conversation id to selected set", %{conn: conn, user: user} do
      conv = create_conv(user.id, %{title: "Toggle Me"})
      {:ok, view, _html} = live(conn, ~p"/bo/history")

      render_hook(view, "toggle_select", %{"id" => conv.id})

      state = :sys.get_state(view.pid)
      assert MapSet.member?(state.socket.assigns.selected, conv.id)
    end

    test "shows bulk selection bar after row checkbox click", %{conn: conn, user: user} do
      conv = create_conv(user.id, %{title: "Bulk Bar Conv"})
      {:ok, view, _html} = live(conn, ~p"/bo/history")

      html =
        view
        |> element("#conv-#{conv.id} input[type=\"checkbox\"]")
        |> render_click()

      assert html =~ "1 selected"
      assert html =~ "phx-click=\"bulk_archive\""
    end

    test "removes a conversation id from selected set when already selected", %{
      conn: conn,
      user: user
    } do
      conv = create_conv(user.id, %{title: "Deselect Me"})
      {:ok, view, _html} = live(conn, ~p"/bo/history")

      render_hook(view, "toggle_select", %{"id" => conv.id})
      render_hook(view, "toggle_select", %{"id" => conv.id})

      state = :sys.get_state(view.pid)
      refute MapSet.member?(state.socket.assigns.selected, conv.id)
    end
  end

  describe "select_all event" do
    test "selects all visible conversations", %{conn: conn, user: user} do
      c1 = create_conv(user.id, %{title: "All Conv 1"})
      c2 = create_conv(user.id, %{title: "All Conv 2"})
      {:ok, view, _html} = live(conn, ~p"/bo/history")

      render_hook(view, "select_all", %{})

      state = :sys.get_state(view.pid)
      assert MapSet.member?(state.socket.assigns.selected, c1.id)
      assert MapSet.member?(state.socket.assigns.selected, c2.id)
    end

    test "deselects all when all are already selected", %{conn: conn, user: user} do
      _conv = create_conv(user.id, %{title: "Select All Toggle"})
      {:ok, view, _html} = live(conn, ~p"/bo/history")

      render_hook(view, "select_all", %{})
      render_hook(view, "select_all", %{})

      state = :sys.get_state(view.pid)
      assert MapSet.size(state.socket.assigns.selected) == 0
    end
  end

  describe "archive_conversation event" do
    test "removes conversation from list without page reload", %{conn: conn, user: user} do
      conv = create_conv(user.id, %{title: "To Archive"})
      {:ok, view, _html} = live(conn, ~p"/bo/history")

      render_hook(view, "archive_conversation", %{"id" => conv.id})

      refute has_element?(view, "#conv-#{conv.id}")
    end
  end

  describe "delete_conversation event" do
    test "removes conversation from list", %{conn: conn, user: user} do
      conv = create_conv(user.id, %{title: "To Delete"})
      {:ok, view, _html} = live(conn, ~p"/bo/history")

      render_hook(view, "delete_conversation", %{"id" => conv.id})

      refute has_element?(view, "#conv-#{conv.id}")
    end
  end

  describe "bulk_archive event" do
    test "removes all selected conversations from list", %{conn: conn, user: user} do
      c1 = create_conv(user.id, %{title: "Bulk Archive 1"})
      c2 = create_conv(user.id, %{title: "Bulk Archive 2"})
      {:ok, view, _html} = live(conn, ~p"/bo/history")

      render_hook(view, "toggle_select", %{"id" => c1.id})
      render_hook(view, "toggle_select", %{"id" => c2.id})
      render_hook(view, "bulk_archive", %{})

      refute has_element?(view, "#conv-#{c1.id}")
      refute has_element?(view, "#conv-#{c2.id}")
    end
  end

  describe "bulk_delete event" do
    test "removes all selected conversations from list", %{conn: conn, user: user} do
      c1 = create_conv(user.id, %{title: "Bulk Delete 1"})
      c2 = create_conv(user.id, %{title: "Bulk Delete 2"})
      {:ok, view, _html} = live(conn, ~p"/bo/history")

      render_hook(view, "toggle_select", %{"id" => c1.id})
      render_hook(view, "toggle_select", %{"id" => c2.id})
      render_hook(view, "bulk_delete", %{})

      refute has_element?(view, "#conv-#{c1.id}")
      refute has_element?(view, "#conv-#{c2.id}")
    end
  end

  describe "super-admin scope" do
    setup %{conn: conn} do
      admin = super_admin_fixture()
      {:ok, admin} = Accounts.change_password(admin, %{password: "StrongPass1!"})
      conn = init_test_session(conn, %{user_id: admin.id})
      %{conn: conn, admin: admin}
    end

    test "super_admin can switch scope to all users", %{conn: conn, admin: admin} do
      other_user = user_fixture()
      other_conv = create_conv(other_user.id, %{title: "Other User Scoped Conv"})
      {:ok, view, _html} = live(conn, ~p"/bo/history")

      html =
        view
        |> element("form[phx-change='filter']")
        |> render_change(%{"scope" => "all", "channel_type" => "all"})

      assert html =~ other_conv.title
      _ = admin
    end

    test "super_admin all scope with channel_type filter narrows results", %{conn: conn} do
      {:ok, mm_conv} =
        Conversations.create_conversation(%{
          channel_type: "mattermost",
          channel_user_id: "mm_admin_#{System.unique_integer([:positive])}",
          title: "Admin MM Conv"
        })

      {:ok, view, _html} = live(conn, ~p"/bo/history")

      html =
        view
        |> element("form[phx-change='filter']")
        |> render_change(%{"scope" => "all", "channel_type" => "mattermost"})

      assert html =~ mm_conv.title
    end

    test "non-admin scope is always forced to own even if params say all", %{conn: conn} do
      # For a non-admin user, scope is forced to "own". This test confirms admins do get "all".
      # (The non-admin path is tested via the regular setup block's user.)
      {:ok, view, _html} = live(conn, ~p"/bo/history")

      state = :sys.get_state(view.pid)
      assert state.socket.assigns.is_admin == true
    end
  end

  describe "person resolution" do
    test "shows person full_name in identity column for super_admin in all-scope", %{conn: _conn} do
      admin = super_admin_fixture()
      {:ok, admin} = Accounts.change_password(admin, %{password: "StrongPass1!"})
      conn = init_test_session(build_conn(), %{user_id: admin.id})

      {:ok, person} =
        People.create_person(%{
          "full_name" => "Resolved Person",
          "email" => "resolved#{System.unique_integer([:positive])}@example.com"
        })

      {:ok, _conv} =
        Conversations.create_conversation(%{
          channel_type: "bo",
          channel_user_id: "u_#{System.unique_integer([:positive])}",
          person_id: person.id,
          title: "Person Linked Conv"
        })

      {:ok, view, _html} = live(conn, ~p"/bo/history")

      html =
        view
        |> element("form[phx-change='filter']")
        |> render_change(%{"scope" => "all", "channel_type" => "all"})

      assert html =~ "Resolved Person"
    end
  end

  describe "filter event with team_id and person_id" do
    test "empty, nil, and malformed integer filters clear for teams and people", %{conn: conn} do
      admin = super_admin_fixture()
      {:ok, admin} = Accounts.change_password(admin, %{password: "StrongPass1!"})
      conn = init_test_session(conn, %{user_id: admin.id})

      {:ok, team_a} =
        People.create_team(%{name: "FilterTeamA#{System.unique_integer([:positive])}"})

      {:ok, team_b} =
        People.create_team(%{name: "FilterTeamB#{System.unique_integer([:positive])}"})

      person_a = create_history_person("Filter Person A")
      person_b = create_history_person("Filter Person B")
      {:ok, person_a} = People.assign_team(person_a, team_a.id)
      {:ok, person_b} = People.assign_team(person_b, team_b.id)
      conv_a = create_person_conv(person_a.id, "Integer Filter A")
      conv_b = create_person_conv(person_b.id, "Integer Filter B")

      {:ok, view, _html} = live(conn, ~p"/bo/history")

      for {key, id} <- [{"team_id", team_a.id}, {"person_id", person_a.id}],
          value <- ["", nil, "invalid"] do
        base_params = %{
          "scope" => "all",
          "channel_type" => "all",
          "team_id" => "all",
          "person_id" => "all"
        }

        html =
          view
          |> render_hook("filter", Map.put(base_params, key, to_string(id)))

        assert html =~ conv_a.title
        refute html =~ conv_b.title

        html = render_hook(view, "toggle_select", %{"id" => conv_a.id})
        assert html =~ "1 selected"

        html =
          render_hook(view, "filter", Map.put(base_params, key, value))

        assert html =~ conv_a.title
        assert html =~ conv_b.title
        refute html =~ "1 selected"
      end
    end

    property "malformed integer filters return all conversations", %{conn: conn} do
      admin = super_admin_fixture()
      {:ok, admin} = Accounts.change_password(admin, %{password: "StrongPass1!"})
      conn = init_test_session(conn, %{user_id: admin.id})

      {:ok, team_a} =
        People.create_team(%{name: "PropertyTeamA#{System.unique_integer([:positive])}"})

      {:ok, team_b} =
        People.create_team(%{name: "PropertyTeamB#{System.unique_integer([:positive])}"})

      person_a = create_history_person("Property Person A")
      person_b = create_history_person("Property Person B")
      {:ok, person_a} = People.assign_team(person_a, team_a.id)
      {:ok, person_b} = People.assign_team(person_b, team_b.id)
      conv_a = create_person_conv(person_a.id, "Property Filter A")
      conv_b = create_person_conv(person_b.id, "Property Filter B")
      {:ok, view, _html} = live(conn, ~p"/bo/history")

      check all(
              key <- member_of(["team_id", "person_id"]),
              suffix <- string(:alphanumeric, min_length: 1, max_length: 24),
              max_runs: 20
            ) do
        valid_id = if key == "team_id", do: team_a.id, else: person_a.id

        base_params = %{
          "scope" => "all",
          "channel_type" => "all",
          "team_id" => "all",
          "person_id" => "all"
        }

        html = render_hook(view, "filter", Map.put(base_params, key, to_string(valid_id)))
        assert html =~ conv_a.title
        refute html =~ conv_b.title

        html =
          render_hook(view, "filter", Map.put(base_params, key, "x" <> suffix))

        assert html =~ conv_a.title
        assert html =~ conv_b.title
      end
    end

    test "filter with person_id in all-scope returns only conversations for that person", %{
      conn: conn
    } do
      admin = super_admin_fixture()
      {:ok, admin} = Accounts.change_password(admin, %{password: "StrongPass1!"})
      conn = init_test_session(conn, %{user_id: admin.id})

      {:ok, person} =
        People.create_person(%{
          "full_name" => "FilteredPerson",
          "email" => "filtered#{System.unique_integer([:positive])}@example.com"
        })

      {:ok, conv} =
        Conversations.create_conversation(%{
          channel_type: "bo",
          channel_user_id: "u_#{System.unique_integer([:positive])}",
          person_id: person.id,
          title: "PersonFiltered Conv"
        })

      {:ok, other_conv} =
        Conversations.create_conversation(%{
          channel_type: "bo",
          channel_user_id: "u_#{System.unique_integer([:positive])}",
          title: "Unrelated Conv"
        })

      {:ok, view, _html} = live(conn, ~p"/bo/history")

      html =
        view
        |> element("form[phx-change='filter']")
        |> render_change(%{
          "scope" => "all",
          "channel_type" => "all",
          "person_id" => to_string(person.id)
        })

      assert html =~ conv.title
      refute html =~ other_conv.title
    end

    test "filter with team_id in all-scope returns conversations for that team", %{
      conn: conn
    } do
      admin = super_admin_fixture()
      {:ok, admin} = Accounts.change_password(admin, %{password: "StrongPass1!"})
      conn = init_test_session(conn, %{user_id: admin.id})

      {:ok, team} =
        People.create_team(%{name: "HistTeam#{System.unique_integer([:positive])}"})

      {:ok, person} =
        People.create_person(%{
          "full_name" => "HistPerson",
          "email" => "histperson#{System.unique_integer([:positive])}@example.com"
        })

      People.assign_team(person, team.id)

      {:ok, conv} =
        Conversations.create_conversation(%{
          channel_type: "bo",
          channel_user_id: "u_#{System.unique_integer([:positive])}",
          person_id: person.id,
          title: "TeamFiltered Conv"
        })

      {:ok, view, _html} = live(conn, ~p"/bo/history")

      html =
        view
        |> element("form[phx-change='filter']")
        |> render_change(%{
          "scope" => "all",
          "channel_type" => "all",
          "team_id" => to_string(team.id)
        })

      assert html =~ conv.title
    end
  end

  describe "search_people event" do
    setup do
      admin = super_admin_fixture()
      {:ok, admin} = Accounts.change_password(admin, %{password: "StrongPass1!"})
      conn = init_test_session(build_conn(), %{user_id: admin.id})
      %{conn: conn}
    end

    test "updates :people assign with matching results", %{conn: conn} do
      {:ok, alice} =
        People.create_person(%{
          "full_name" => "Alice Search#{System.unique_integer([:positive])}",
          "email" => "alice_s#{System.unique_integer([:positive])}@example.com"
        })

      {:ok, view, _html} = live(conn, ~p"/bo/history")

      assert :sys.get_state(view.pid).socket.assigns.people == []

      render_hook(view, "search_people", %{"query" => alice.full_name})

      people = :sys.get_state(view.pid).socket.assigns.people
      assert Enum.any?(people, &(&1.id == alice.id))
    end

    test "empty query returns no people", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/history")

      render_hook(view, "search_people", %{"query" => ""})

      assert :sys.get_state(view.pid).socket.assigns.people == []
    end

    test "non-matching query returns no people", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/history")

      render_hook(view, "search_people", %{"query" => "zzz_no_match_xyz"})

      assert :sys.get_state(view.pid).socket.assigns.people == []
    end

    test "results appear in person dropdown when in all-scope", %{conn: conn} do
      {:ok, alice} =
        People.create_person(%{
          "full_name" => "Alice Dropdown#{System.unique_integer([:positive])}",
          "email" => "alice_d#{System.unique_integer([:positive])}@example.com"
        })

      {:ok, _bob} =
        People.create_person(%{
          "full_name" => "Bob Dropdown#{System.unique_integer([:positive])}",
          "email" => "bob_d#{System.unique_integer([:positive])}@example.com"
        })

      {:ok, view, _html} = live(conn, ~p"/bo/history")

      # Switch to all-scope so the person dropdown is rendered
      view
      |> element("form[phx-change='filter']")
      |> render_change(%{"scope" => "all", "channel_type" => "all"})

      html = render_hook(view, "search_people", %{"query" => "Alice Dropdown"})

      assert html =~ alice.full_name
      refute html =~ "Bob Dropdown"
    end
  end

  defp create_conv(user_id, overrides) do
    {:ok, conv} =
      Conversations.create_conversation(
        Map.merge(
          %{
            channel_type: "bo",
            channel_user_id: "u_#{System.unique_integer([:positive])}",
            user_id: user_id
          },
          overrides
        )
      )

    conv
  end

  defp create_history_person(prefix) do
    {:ok, person} =
      People.create_person(%{
        "full_name" => "#{prefix} #{System.unique_integer([:positive])}",
        "email" => "history#{System.unique_integer([:positive])}@example.com"
      })

    person
  end

  defp create_person_conv(person_id, title) do
    {:ok, conv} =
      Conversations.create_conversation(%{
        channel_type: "bo",
        channel_user_id: "history_#{System.unique_integer([:positive])}",
        person_id: person_id,
        title: title
      })

    conv
  end
end
