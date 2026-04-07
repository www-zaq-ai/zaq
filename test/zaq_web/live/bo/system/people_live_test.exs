defmodule ZaqWeb.Live.BO.System.PeopleLiveTest do
  use ZaqWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures

  alias Zaq.Accounts
  alias Zaq.Accounts.People

  setup %{conn: conn} do
    user = admin_fixture(%{username: "people_live_admin_#{System.unique_integer([:positive])}"})
    {:ok, user} = Accounts.change_password(user, %{password: "StrongPass1!"})
    conn = init_test_session(conn, %{user_id: user.id})

    %{conn: conn, user: user}
  end

  defp person_fixture(attrs \\ %{}) do
    {:ok, person} =
      Map.merge(
        %{
          "full_name" => "Person #{System.unique_integer([:positive])}",
          "email" => "p#{System.unique_integer([:positive])}@example.com"
        },
        attrs
      )
      |> People.create_person()

    People.get_person_with_channels!(person.id)
  end

  defp team_fixture(attrs \\ %{}) do
    {:ok, team} =
      People.create_team(Map.merge(%{name: "Team #{System.unique_integer([:positive])}"}, attrs))

    team
  end

  defp channel_fixture(person, attrs) do
    {:ok, channel} =
      People.add_channel(
        Map.merge(
          %{
            "person_id" => person.id,
            "platform" => "slack",
            "channel_identifier" => "@chan-#{System.unique_integer([:positive])}"
          },
          attrs
        )
      )

    channel
  end

  # ── Mount ─────────────────────────────────────────────────────────────────

  test "mounts and renders the people tab by default", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/bo/people")
    assert html =~ "People"
  end

  # ── Person CRUD ───────────────────────────────────────────────────────────

  test "new person button opens modal and creates person", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/people")

    view |> element("#new-person-button") |> render_click()

    assert has_element?(view, "#people-modal-overlay")
    assert has_element?(view, "h3", "New Person")

    view
    |> form("#person-modal-form", %{
      "person" => %{
        "full_name" => "Jane Smith",
        "email" => "jane.smith.#{System.unique_integer([:positive])}@example.com",
        "role" => "Senior Engineer",
        "status" => "active"
      }
    })
    |> render_submit()

    assert has_element?(view, "[phx-click='select_person']", "Jane Smith")
  end

  test "edit person modal pre-fills existing data", %{conn: conn} do
    person = person_fixture(%{"full_name" => "Edit Target"})
    {:ok, view, _html} = live(conn, ~p"/bo/people")

    # Select the person first to open the detail panel which contains the edit button
    view
    |> element("[phx-click='select_person'][phx-value-id='#{person.id}']")
    |> render_click()

    view
    |> element("[phx-click='open_modal'][phx-value-action='edit'][phx-value-id='#{person.id}']")
    |> render_click()

    assert has_element?(view, "#people-modal-overlay")
    assert has_element?(view, "h3", "Edit Person")
    html = render(view)
    assert html =~ "Edit Target"
  end

  test "save with invalid data keeps modal open with errors", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/people")

    view |> element("#new-person-button") |> render_click()

    view
    |> form("#person-modal-form", %{"person" => %{"full_name" => ""}})
    |> render_submit()

    assert has_element?(view, "#people-modal-overlay")
  end

  # ── Select / deselect ─────────────────────────────────────────────────────

  test "selecting a person opens the detail panel", %{conn: conn} do
    person = person_fixture(%{"full_name" => "Detail Person"})
    {:ok, view, _html} = live(conn, ~p"/bo/people")

    view
    |> element("[phx-click='select_person'][phx-value-id='#{person.id}']")
    |> render_click()

    assert has_element?(view, "[phx-click='deselect_person']")
    assert render(view) =~ "Detail Person"
  end

  test "deselecting hides the detail panel", %{conn: conn} do
    person = person_fixture()
    {:ok, view, _html} = live(conn, ~p"/bo/people")

    view
    |> element("[phx-click='select_person'][phx-value-id='#{person.id}']")
    |> render_click()

    view |> element("[phx-click='deselect_person']") |> render_click()

    refute has_element?(view, "[phx-click='deselect_person']")
  end

  # ── Delete ────────────────────────────────────────────────────────────────

  test "confirm_delete shows the confirm bar", %{conn: conn} do
    person = person_fixture()
    {:ok, view, _html} = live(conn, ~p"/bo/people")

    # The confirm_delete button is in the detail panel — select the person first
    view
    |> element("[phx-click='select_person'][phx-value-id='#{person.id}']")
    |> render_click()

    view
    |> element(
      "[phx-click='confirm_delete'][phx-value-entity='person'][phx-value-id='#{person.id}']"
    )
    |> render_click()

    assert has_element?(view, "[phx-click='delete']")
  end

  test "delete removes person from list", %{conn: conn} do
    person = person_fixture(%{"full_name" => "To Be Deleted"})
    {:ok, view, _html} = live(conn, ~p"/bo/people")

    # The confirm_delete button is in the detail panel — select the person first
    view
    |> element("[phx-click='select_person'][phx-value-id='#{person.id}']")
    |> render_click()

    view
    |> element(
      "[phx-click='confirm_delete'][phx-value-entity='person'][phx-value-id='#{person.id}']"
    )
    |> render_click()

    view |> element("[phx-click='delete']") |> render_click()

    refute has_element?(view, "[phx-click='select_person'][phx-value-id='#{person.id}']")
  end

  test "cancel_delete hides confirm bar", %{conn: conn} do
    person = person_fixture()
    {:ok, view, _html} = live(conn, ~p"/bo/people")

    # The confirm_delete button is in the detail panel — select the person first
    view
    |> element("[phx-click='select_person'][phx-value-id='#{person.id}']")
    |> render_click()

    view
    |> element(
      "[phx-click='confirm_delete'][phx-value-entity='person'][phx-value-id='#{person.id}']"
    )
    |> render_click()

    view |> element("[phx-click='cancel_delete']") |> render_click()

    refute has_element?(view, "[phx-click='delete']")
  end

  # ── Filtering ─────────────────────────────────────────────────────────────

  test "filter by name shows only matching people", %{conn: conn} do
    unique = "FilterTarget#{System.unique_integer([:positive])}"
    person_fixture(%{"full_name" => unique})
    other = person_fixture(%{"full_name" => "OtherPerson#{System.unique_integer([:positive])}"})

    {:ok, view, _html} = live(conn, ~p"/bo/people")

    view
    |> form("[phx-change='filter_people']", %{
      "filter_name" => unique,
      "filter_email" => "",
      "filter_phone" => "",
      "filter_complete" => "all",
      "filter_team_id" => ""
    })
    |> render_change()

    assert render(view) =~ unique
    refute render(view) =~ other.full_name
  end

  test "filter by complete shows only complete people", %{conn: conn} do
    ts = System.unique_integer([:positive])

    {:ok, complete} =
      People.create_person(%{
        "full_name" => "CompleteFilter#{ts}",
        "email" => "cf#{ts}@example.com",
        "phone" => "+10000#{ts}"
      })

    incomplete = person_fixture(%{"full_name" => "IncompleteFilter#{ts}"})

    {:ok, view, _html} = live(conn, ~p"/bo/people")

    view
    |> form("[phx-change='filter_people']", %{
      "filter_name" => "#{ts}",
      "filter_email" => "",
      "filter_phone" => "",
      "filter_complete" => "complete",
      "filter_team_id" => ""
    })
    |> render_change()

    html = render(view)
    assert html =~ complete.full_name
    refute html =~ incomplete.full_name
  end

  # ── Pagination ────────────────────────────────────────────────────────────

  test "change_page event updates displayed page", %{conn: conn} do
    # Create 25 people (per_page is 20) with a shared name prefix for isolation
    ts = System.unique_integer([:positive])

    for i <- 1..25 do
      People.create_person(%{
        "full_name" => "Pag#{ts} Person #{String.pad_leading(to_string(i), 2, "0")}",
        "email" => "pag#{ts}p#{i}@example.com"
      })
    end

    {:ok, view, _html} = live(conn, ~p"/bo/people")

    # Filter to only our 25 people
    view
    |> form("[phx-change='filter_people']", %{
      "filter_name" => "Pag#{ts}",
      "filter_email" => "",
      "filter_phone" => "",
      "filter_complete" => "all",
      "filter_team_id" => ""
    })
    |> render_change()

    # Page 1 has 20, so next button should appear
    assert has_element?(view, "button", "Next →")

    view |> element("button", "Next →") |> render_click()

    # Prev should now appear
    assert has_element?(view, "button", "← Prev")
  end

  # ── Channels ─────────────────────────────────────────────────────────────

  test "add new channel button opens modal and creates channel", %{conn: conn} do
    person = person_fixture(%{"full_name" => "Modal Channel Owner"})
    {:ok, view, _html} = live(conn, ~p"/bo/people")

    view
    |> element("[phx-click='select_person'][phx-value-id='#{person.id}']")
    |> render_click()

    view |> element("#add-channel-button") |> render_click()

    assert has_element?(view, "#people-modal-overlay")
    assert has_element?(view, "h3", "Add Channel")

    channel_identifier = "@modal-#{System.unique_integer([:positive])}"

    view
    |> form("#channel-modal-form", %{
      "channel" => %{"platform" => "slack", "channel_identifier" => channel_identifier}
    })
    |> render_submit()

    assert render(view) =~ channel_identifier
  end

  # ── Teams tab ─────────────────────────────────────────────────────────────

  test "switching to Teams tab shows team list", %{conn: conn} do
    team = team_fixture()
    {:ok, view, _html} = live(conn, ~p"/bo/people")

    view |> element("[phx-value-tab='teams']") |> render_click()

    assert has_element?(view, "#new-team-button")
    assert render(view) =~ team.name
  end

  test "new team button opens modal and creates team", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/people")

    view |> element("[phx-value-tab='teams']") |> render_click()
    view |> element("#new-team-button") |> render_click()

    assert has_element?(view, "#people-modal-overlay")
    assert has_element?(view, "h3", "New Team")

    team_name = "LiveView Team #{System.unique_integer([:positive])}"

    view
    |> form("#team-modal-form", %{"team" => %{"name" => team_name}})
    |> render_submit()

    assert render(view) =~ team_name
  end

  test "delete team removes it and cleans up assigned persons", %{conn: conn} do
    team = team_fixture()
    person = person_fixture()
    People.assign_team(person, team.id)

    {:ok, view, _html} = live(conn, ~p"/bo/people")

    view |> element("[phx-value-tab='teams']") |> render_click()

    view
    |> element("[phx-click='confirm_delete'][phx-value-entity='team'][phx-value-id='#{team.id}']")
    |> render_click()

    view |> element("[phx-click='delete']") |> render_click()

    refute render(view) =~ team.name

    updated = People.get_person!(person.id)
    refute team.id in updated.team_ids
  end

  # ── Team assignment ───────────────────────────────────────────────────────

  test "assign_team_select assigns team to selected person", %{conn: conn} do
    team = team_fixture(%{name: "Assignable#{System.unique_integer([:positive])}"})
    person = person_fixture()

    {:ok, view, _html} = live(conn, ~p"/bo/people")

    view
    |> element("[phx-click='select_person'][phx-value-id='#{person.id}']")
    |> render_click()

    # The SearchableSelect component uses a JS hook to update the hidden input and submit.
    # In tests we fire the event directly to avoid hidden-input value validation.
    render_hook(view, "assign_team_select", %{"team_id" => to_string(team.id)})

    updated = People.get_person!(person.id)
    assert team.id in updated.team_ids
  end

  # ── Merge ─────────────────────────────────────────────────────────────────

  test "merge flow: open modal, search, select loser, confirm", %{conn: conn} do
    survivor = person_fixture(%{"full_name" => "Survivor#{System.unique_integer([:positive])}"})
    loser = person_fixture(%{"full_name" => "Loser#{System.unique_integer([:positive])}"})

    {:ok, view, _html} = live(conn, ~p"/bo/people")

    # Select survivor and open merge modal
    view
    |> element("[phx-click='select_person'][phx-value-id='#{survivor.id}']")
    |> render_click()

    view
    |> element("[phx-click='open_merge_modal'][phx-value-id='#{survivor.id}']")
    |> render_click()

    assert has_element?(view, "#people-modal-overlay")
    assert render(view) =~ "Merge Persons"

    # Search for loser
    view
    |> form("[phx-change='merge_search']", %{"merge_search" => loser.full_name})
    |> render_change()

    assert has_element?(view, "[phx-click='select_merge_loser'][phx-value-id='#{loser.id}']")

    # Select loser
    view
    |> element("[phx-click='select_merge_loser'][phx-value-id='#{loser.id}']")
    |> render_click()

    assert has_element?(view, "[phx-click='confirm_merge']")

    # Confirm merge
    view |> element("[phx-click='confirm_merge']") |> render_click()

    refute has_element?(view, "#people-modal-overlay")
    assert render(view) =~ "Persons merged successfully"

    assert_raise Ecto.NoResultsError, fn -> People.get_person!(loser.id) end
  end

  test "merge carries team_ids from loser to survivor", %{conn: conn} do
    {:ok, team_a} = People.create_team(%{name: "MergeTeamA#{System.unique_integer([:positive])}"})
    {:ok, team_b} = People.create_team(%{name: "MergeTeamB#{System.unique_integer([:positive])}"})

    survivor = person_fixture()
    loser = person_fixture()

    {:ok, survivor} = People.assign_team(survivor, team_a.id)
    {:ok, loser} = People.assign_team(loser, team_b.id)

    survivor = People.get_person_with_channels!(survivor.id)
    loser = People.get_person_with_channels!(loser.id)

    {:ok, updated} = People.merge_persons(survivor, loser)
    assert team_a.id in updated.team_ids
    assert team_b.id in updated.team_ids
  end

  test "open_merge_modal with role=loser sets person as merge loser", %{conn: conn} do
    loser = person_fixture(%{"full_name" => "Loser Role#{System.unique_integer([:positive])}"})
    {:ok, view, _html} = live(conn, ~p"/bo/people")

    render_hook(view, "open_merge_modal", %{"id" => to_string(loser.id), "role" => "loser"})

    assert has_element?(view, "#people-modal-overlay")
    assert render(view) =~ "Merge Persons"
  end

  test "select_merge_survivor changes the survivor in merge modal", %{conn: conn} do
    survivor_a =
      person_fixture(%{"full_name" => "SurvivorA#{System.unique_integer([:positive])}"})

    survivor_b =
      person_fixture(%{"full_name" => "SurvivorB#{System.unique_integer([:positive])}"})

    {:ok, view, _html} = live(conn, ~p"/bo/people")

    # Open merge modal with survivor_a as survivor
    view
    |> element("[phx-click='select_person'][phx-value-id='#{survivor_a.id}']")
    |> render_click()

    view
    |> element("[phx-click='open_merge_modal'][phx-value-id='#{survivor_a.id}']")
    |> render_click()

    # Change survivor to survivor_b
    render_hook(view, "select_merge_survivor", %{"id" => to_string(survivor_b.id)})

    assert render(view) =~ survivor_b.full_name
  end

  test "merge_search with query shorter than 2 chars returns no candidates", %{conn: conn} do
    survivor = person_fixture()
    {:ok, view, _html} = live(conn, ~p"/bo/people")

    view
    |> element("[phx-click='select_person'][phx-value-id='#{survivor.id}']")
    |> render_click()

    view
    |> element("[phx-click='open_merge_modal'][phx-value-id='#{survivor.id}']")
    |> render_click()

    view
    |> form("[phx-change='merge_search']", %{"merge_search" => "x"})
    |> render_change()

    # With query < 2 chars, no candidates section should appear
    refute has_element?(view, "[phx-click='select_merge_loser']")
  end

  test "close_modal dismisses the merge modal", %{conn: conn} do
    person = person_fixture()
    {:ok, view, _html} = live(conn, ~p"/bo/people")

    view
    |> element("[phx-click='select_person'][phx-value-id='#{person.id}']")
    |> render_click()

    view
    |> element("[phx-click='open_merge_modal'][phx-value-id='#{person.id}']")
    |> render_click()

    assert has_element?(view, "#people-modal-overlay")

    render_hook(view, "close_modal", %{})

    refute has_element?(view, "#people-modal-overlay")
  end

  test "validate event updates changeset errors for new person form", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/people")

    view |> element("#new-person-button") |> render_click()

    view
    |> form("#person-modal-form", %{"person" => %{"full_name" => ""}})
    |> render_change()

    assert has_element?(view, "#people-modal-overlay")
  end

  test "validate event in edit mode uses update_changeset", %{conn: conn} do
    person = person_fixture(%{"full_name" => "Edit Validate Target"})
    {:ok, view, _html} = live(conn, ~p"/bo/people")

    view
    |> element("[phx-click='select_person'][phx-value-id='#{person.id}']")
    |> render_click()

    view
    |> element("[phx-click='open_modal'][phx-value-action='edit'][phx-value-id='#{person.id}']")
    |> render_click()

    view
    |> form("#person-modal-form", %{"person" => %{"full_name" => "Updated Name"}})
    |> render_change()

    assert has_element?(view, "#people-modal-overlay")
  end

  test "edit channel modal pre-fills existing channel data", %{conn: conn} do
    person = person_fixture(%{"full_name" => "Channel Edit Owner"})

    {:ok, _channel} =
      People.add_channel(%{
        "person_id" => person.id,
        "platform" => "slack",
        "channel_identifier" => "@edit-me"
      })

    person = People.get_person_with_channels!(person.id)
    channel = hd(person.channels)

    {:ok, view, _html} = live(conn, ~p"/bo/people")

    view
    |> element("[phx-click='select_person'][phx-value-id='#{person.id}']")
    |> render_click()

    view
    |> element(
      "[phx-click='open_modal'][phx-value-action='edit'][phx-value-entity='channel'][phx-value-id='#{channel.id}']"
    )
    |> render_click()

    assert has_element?(view, "#people-modal-overlay")
    html = render(view)
    assert html =~ "@edit-me"
  end

  test "edit team modal pre-fills existing team data", %{conn: conn} do
    team = team_fixture(%{name: "Editable Team#{System.unique_integer([:positive])}"})
    {:ok, view, _html} = live(conn, ~p"/bo/people")

    view |> element("[phx-value-tab='teams']") |> render_click()

    view
    |> element(
      "[phx-click='open_modal'][phx-value-action='edit'][phx-value-entity='team'][phx-value-id='#{team.id}']"
    )
    |> render_click()

    assert has_element?(view, "#people-modal-overlay")
    html = render(view)
    assert html =~ team.name
  end

  test "validate channel form updates changeset in modal", %{conn: conn} do
    person = person_fixture()
    {:ok, view, _html} = live(conn, ~p"/bo/people")

    view
    |> element("[phx-click='select_person'][phx-value-id='#{person.id}']")
    |> render_click()

    view |> element("#add-channel-button") |> render_click()

    view
    |> form("#channel-modal-form", %{"channel" => %{"platform" => "", "channel_identifier" => ""}})
    |> render_change()

    assert has_element?(view, "#people-modal-overlay")
  end

  test "validate team form updates changeset in modal", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/people")

    view |> element("[phx-value-tab='teams']") |> render_click()
    view |> element("#new-team-button") |> render_click()

    view
    |> form("#team-modal-form", %{"team" => %{"name" => ""}})
    |> render_change()

    assert has_element?(view, "#people-modal-overlay")
  end

  test "save channel with invalid attrs keeps modal open", %{conn: conn} do
    person = person_fixture()
    {:ok, view, _html} = live(conn, ~p"/bo/people")

    view
    |> element("[phx-click='select_person'][phx-value-id='#{person.id}']")
    |> render_click()

    view |> element("#add-channel-button") |> render_click()

    view
    |> form("#channel-modal-form", %{"channel" => %{"platform" => "", "channel_identifier" => ""}})
    |> render_submit()

    assert has_element?(view, "#people-modal-overlay")
  end

  test "save team edit updates existing team", %{conn: conn} do
    team = team_fixture(%{name: "Before Team Name#{System.unique_integer([:positive])}"})
    {:ok, view, _html} = live(conn, ~p"/bo/people")

    view |> element("[phx-value-tab='teams']") |> render_click()

    view
    |> element(
      "[phx-click='open_modal'][phx-value-action='edit'][phx-value-entity='team'][phx-value-id='#{team.id}']"
    )
    |> render_click()

    new_name = "After Team Name#{System.unique_integer([:positive])}"

    view
    |> form("#team-modal-form", %{"team" => %{"name" => new_name}})
    |> render_submit()

    assert render(view) =~ new_name
  end

  test "delete channel removes it from person detail", %{conn: conn} do
    person = person_fixture()
    channel = channel_fixture(person, %{"channel_identifier" => "@delete-me"})

    {:ok, view, _html} = live(conn, ~p"/bo/people")

    view
    |> element("[phx-click='select_person'][phx-value-id='#{person.id}']")
    |> render_click()

    assert render(view) =~ "@delete-me"

    view
    |> element(
      "[phx-click='confirm_delete'][phx-value-entity='channel'][phx-value-id='#{channel.id}']"
    )
    |> render_click()

    view |> element("[phx-click='delete']") |> render_click()

    refute render(view) =~ "@delete-me"
  end

  test "move_channel_up and move_channel_down reorder channels", %{conn: conn} do
    person = person_fixture()
    c1 = channel_fixture(person, %{"channel_identifier" => "@ch-first"})
    c2 = channel_fixture(person, %{"channel_identifier" => "@ch-second"})

    {:ok, view, _html} = live(conn, ~p"/bo/people")

    view
    |> element("[phx-click='select_person'][phx-value-id='#{person.id}']")
    |> render_click()

    render_hook(view, "move_channel_up", %{"channel_id" => to_string(c2.id)})
    person_after_up = People.get_person_with_channels!(person.id)
    assert hd(person_after_up.channels).id == c2.id

    render_hook(view, "move_channel_down", %{"channel_id" => to_string(c2.id)})
    person_after_down = People.get_person_with_channels!(person.id)
    assert hd(person_after_down.channels).id == c1.id
  end

  test "move_channel_up/down no-op branches keep order", %{conn: conn} do
    person = person_fixture()
    c1 = channel_fixture(person, %{"channel_identifier" => "@noop-first"})
    c2 = channel_fixture(person, %{"channel_identifier" => "@noop-second"})

    {:ok, view, _html} = live(conn, ~p"/bo/people")

    view
    |> element("[phx-click='select_person'][phx-value-id='#{person.id}']")
    |> render_click()

    render_hook(view, "move_channel_up", %{"channel_id" => to_string(c1.id)})
    render_hook(view, "move_channel_down", %{"channel_id" => to_string(c2.id)})

    person_after = People.get_person_with_channels!(person.id)
    assert Enum.map(person_after.channels, & &1.id) == [c1.id, c2.id]
  end

  test "assign_team_select with empty team id is a no-op", %{conn: conn} do
    person = person_fixture()
    {:ok, view, _html} = live(conn, ~p"/bo/people")

    view
    |> element("[phx-click='select_person'][phx-value-id='#{person.id}']")
    |> render_click()

    before = People.get_person!(person.id)
    render_hook(view, "assign_team_select", %{"team_id" => ""})
    after_person = People.get_person!(person.id)

    assert after_person.team_ids == before.team_ids
  end

  test "toggle_team adds and removes team assignment", %{conn: conn} do
    person = person_fixture()
    team = team_fixture(%{name: "ToggleTeam#{System.unique_integer([:positive])}"})

    {:ok, view, _html} = live(conn, ~p"/bo/people")

    view
    |> element("[phx-click='select_person'][phx-value-id='#{person.id}']")
    |> render_click()

    render_hook(view, "toggle_team", %{"team_id" => to_string(team.id)})
    assert team.id in People.get_person!(person.id).team_ids

    render_hook(view, "toggle_team", %{"team_id" => to_string(team.id)})
    refute team.id in People.get_person!(person.id).team_ids
  end

  test "create_and_assign_team creates a team and assigns it", %{conn: conn} do
    person = person_fixture()
    {:ok, view, _html} = live(conn, ~p"/bo/people")

    view
    |> element("[phx-click='select_person'][phx-value-id='#{person.id}']")
    |> render_click()

    team_name = "HookCreateTeam#{System.unique_integer([:positive])}"
    render_hook(view, "create_and_assign_team", %{"name" => team_name})

    assert render(view) =~ "created and assigned"

    [created_team] = Enum.filter(People.list_teams(), &(&1.name == team_name))
    assert created_team.id in People.get_person!(person.id).team_ids
  end
end
