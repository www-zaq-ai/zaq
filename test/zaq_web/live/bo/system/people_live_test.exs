defmodule ZaqWeb.Live.BO.System.PeopleLiveTest do
  use ZaqWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures
  import Zaq.SystemConfigFixtures

  alias Zaq.Accounts
  alias Zaq.Accounts.People
  alias Zaq.Channels.AgentRouting
  alias Zaq.Channels.ChannelConfig
  alias Zaq.Channels.RetrievalChannel
  alias Zaq.Engine.IncomingMessageRouting
  alias Zaq.Ingestion
  alias Zaq.Ingestion.Document
  alias Zaq.Repo

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
    |> element(
      "[phx-click='open_modal'][phx-value-action='edit'][phx-value-entity='person'][phx-value-id='#{person.id}']"
    )
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

  test "bulk delete button shows selected count and opens popup", %{conn: conn} do
    person = person_fixture()
    {:ok, view, _html} = live(conn, ~p"/bo/people")

    refute has_element?(view, "#bulk-delete-button")

    view
    |> element("[phx-click='toggle_person_selection'][phx-value-id='#{person.id}']")
    |> render_click()

    assert has_element?(view, "#bulk-delete-button", "Delete selected")

    view |> element("#bulk-delete-button") |> render_click()

    assert has_element?(view, "[phx-click='confirm_bulk_delete']")
  end

  test "confirm bulk delete removes selected people", %{conn: conn} do
    person = person_fixture(%{"full_name" => "Bulk Delete Person"})
    {:ok, view, _html} = live(conn, ~p"/bo/people")

    view
    |> element("[phx-click='toggle_person_selection'][phx-value-id='#{person.id}']")
    |> render_click()

    view |> element("#bulk-delete-button") |> render_click()
    view |> element("[phx-click='confirm_bulk_delete']") |> render_click()

    refute has_element?(view, "[phx-click='select_person'][phx-value-id='#{person.id}']")
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

  test "edit person modal saves person-scoped global routing", %{conn: conn} do
    person = person_fixture(%{"full_name" => "Routed Person"})
    agent = create_conversation_agent(true, "people-global")

    {:ok, view, _html} = live(conn, ~p"/bo/people")

    view
    |> element("[phx-click='select_person'][phx-value-id='#{person.id}']")
    |> render_click()

    view
    |> element(
      "[phx-click='open_modal'][phx-value-action='edit'][phx-value-entity='person'][phx-value-id='#{person.id}']"
    )
    |> render_click()

    assert has_element?(view, "#person-global-routing-select")

    view
    |> form("#person-modal-form", %{
      "person" => %{
        "full_name" => "Routed Person",
        "routing_agent_id" => to_string(agent.id)
      }
    })
    |> render_submit()

    assert IncomingMessageRouting.get_rule(%{person_id: person.id}).configured_agent_id ==
             agent.id

    assert render(view) =~ "routes:"
  end

  test "channel edit modal saves person provider and retrieval routing", %{conn: conn} do
    person = person_fixture(%{"full_name" => "Channel Routed"})

    channel =
      channel_fixture(person, %{"platform" => "slack", "channel_identifier" => "@routing"})

    config = insert_channel_config(%{provider: "slack", name: "Slack Workspace"})

    retrieval =
      insert_retrieval_channel(config, %{channel_name: "support", channel_id: "support-1"})

    provider_agent = create_conversation_agent(true, "people-provider")
    retrieval_agent = create_conversation_agent(true, "people-retrieval")

    {:ok, view, _html} = live(conn, ~p"/bo/people")

    view
    |> element("[phx-click='select_person'][phx-value-id='#{person.id}']")
    |> render_click()

    assert render(view) =~ "Slack Workspace"

    view
    |> element(
      "[phx-click='open_modal'][phx-value-action='edit'][phx-value-entity='channel'][phx-value-id='#{channel.id}']"
    )
    |> render_click()

    assert has_element?(view, "#person-provider-routing-select-#{config.id}")
    assert has_element?(view, "#person-retrieval-routing-select-#{retrieval.id}")

    view
    |> form("#channel-modal-form", %{
      "channel" => %{
        "platform" => "slack",
        "channel_identifier" => "@routing",
        "provider_agent_ids" => %{to_string(config.id) => to_string(provider_agent.id)},
        "retrieval_agent_ids" => %{to_string(retrieval.id) => to_string(retrieval_agent.id)}
      }
    })
    |> render_submit()

    assert IncomingMessageRouting.get_rule(%{
             person_id: person.id,
             channel_config_id: config.id
           }).configured_agent_id == provider_agent.id

    assert IncomingMessageRouting.get_rule(%{
             person_id: person.id,
             channel_config_id: config.id,
             retrieval_channel_id: retrieval.id
           }).configured_agent_id == retrieval_agent.id
  end

  test "email person channel uses imap receiving config and saves mailbox routing", %{conn: conn} do
    person = person_fixture(%{"full_name" => "Email Routed"})

    channel_fixture(person, %{"platform" => "email", "channel_identifier" => "routed@example.com"})

    assert {:ok, _smtp} =
             ChannelConfig.upsert_by_provider("email:smtp", %{
               name: "Email SMTP",
               kind: "retrieval",
               enabled: true,
               settings: %{"relay" => "smtp.example.com", "port" => "587"}
             })

    assert {:ok, imap} =
             ChannelConfig.upsert_by_provider("email:imap", %{
               name: "Email IMAP",
               kind: "retrieval",
               enabled: true,
               url: "imap.example.com",
               token: "imap-token",
               settings: %{"imap" => %{"selected_mailboxes" => ["INBOX", "Support"]}}
             })

    agent = create_conversation_agent(true, "people-mailbox")

    {:ok, view, _html} = live(conn, ~p"/bo/people")

    view
    |> element("[phx-click='select_person'][phx-value-id='#{person.id}']")
    |> render_click()

    html = render(view)
    assert html =~ "Email IMAP"
    refute html =~ "Email SMTP"
    assert html =~ "mailbox INBOX"

    channel =
      person.id
      |> People.get_person_with_channels!()
      |> Map.fetch!(:channels)
      |> Enum.find(&(&1.channel_identifier == "routed@example.com"))

    view
    |> element(
      "[phx-click='open_modal'][phx-value-action='edit'][phx-value-entity='channel'][phx-value-id='#{channel.id}']"
    )
    |> render_click()

    assert has_element?(view, "#person-topic-routing-select-#{imap.id}-SU5CT1g")

    view
    |> form("#channel-modal-form", %{
      "channel" => %{
        "platform" => "email",
        "channel_identifier" => "routed@example.com",
        "topic_agent_ids" => %{
          to_string(imap.id) => %{
            "INBOX" => AgentRouting.none_value(),
            "Support" => to_string(agent.id)
          }
        }
      }
    })
    |> render_submit()

    assert IncomingMessageRouting.get_rule(%{
             person_id: person.id,
             channel_config_id: imap.id,
             topic_id: "INBOX"
           }).routing_mode == :none

    assert IncomingMessageRouting.get_rule(%{
             person_id: person.id,
             channel_config_id: imap.id,
             topic_id: "Support"
           }).configured_agent_id == agent.id
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

  test "merge carries team_ids from loser to survivor", %{conn: _conn} do
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
    |> element(
      "[phx-click='open_modal'][phx-value-action='edit'][phx-value-entity='person'][phx-value-id='#{person.id}']"
    )
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
    person = person_fixture(%{"email" => nil})
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
    person = person_fixture(%{"email" => nil})
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

  test "selecting a person loads person_documents from permissions", %{conn: conn} do
    person = person_fixture()

    {:ok, doc} =
      Document.create(%{source: "person-doc-#{person.id}.md", content: "doc"})

    {:ok, _} = Ingestion.set_document_permission(doc.id, :person, person.id, ["read"])

    {:ok, view, _html} = live(conn, ~p"/bo/people")

    view
    |> element("[phx-click='select_person'][phx-value-id='#{person.id}']")
    |> render_click()

    state = :sys.get_state(view.pid)
    person_documents = state.socket.assigns.person_documents
    assert Enum.any?(person_documents, &(&1.person_id == person.id))
  end

  test "deselecting a person clears person_documents", %{conn: conn} do
    person = person_fixture()
    {:ok, view, _html} = live(conn, ~p"/bo/people")

    view
    |> element("[phx-click='select_person'][phx-value-id='#{person.id}']")
    |> render_click()

    view |> element("[phx-click='deselect_person']") |> render_click()

    state = :sys.get_state(view.pid)
    assert state.socket.assigns.person_documents == []
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

  # ── handle_params with person_id ─────────────────────────────────────────

  test "navigating to /bo/people?person_id=<id> pre-selects person", %{conn: conn} do
    person = person_fixture(%{"full_name" => "Pre-Selected Person"})

    {:ok, view, _html} = live(conn, ~p"/bo/people?person_id=#{person.id}")

    state = :sys.get_state(view.pid)
    assert state.socket.assigns.selected_person.id == person.id
  end

  test "navigating to /bo/people?person_id=<nonexistent> does not crash", %{conn: conn} do
    {:ok, _view, _html} = live(conn, ~p"/bo/people?person_id=99999999")
  end

  # ── save person edit ─────────────────────────────────────────────────────

  test "save person edit updates person and refreshes list", %{conn: conn} do
    person = person_fixture(%{"full_name" => "Before Edit Name"})

    {:ok, view, _html} = live(conn, ~p"/bo/people")

    view
    |> element("[phx-click='select_person'][phx-value-id='#{person.id}']")
    |> render_click()

    view
    |> element(
      "[phx-click='open_modal'][phx-value-action='edit'][phx-value-entity='person'][phx-value-id='#{person.id}']"
    )
    |> render_click()

    new_name = "After Edit Name#{System.unique_integer([:positive])}"

    view
    |> form("#person-modal-form", %{
      "person" => %{"full_name" => new_name, "email" => person.email}
    })
    |> render_submit()

    assert render(view) =~ new_name
  end

  # ── toggle_person_selection deselect branch ──────────────────────────────

  test "toggling an already-selected person deselects it", %{conn: conn} do
    person = person_fixture()
    {:ok, view, _html} = live(conn, ~p"/bo/people")

    view
    |> element("[phx-click='toggle_person_selection'][phx-value-id='#{person.id}']")
    |> render_click()

    assert has_element?(view, "#bulk-delete-button")

    view
    |> element("[phx-click='toggle_person_selection'][phx-value-id='#{person.id}']")
    |> render_click()

    refute has_element?(view, "#bulk-delete-button")
  end

  # ── cancel_bulk_delete ────────────────────────────────────────────────────

  test "cancel_bulk_delete closes the confirmation popup", %{conn: conn} do
    person = person_fixture()
    {:ok, view, _html} = live(conn, ~p"/bo/people")

    view
    |> element("[phx-click='toggle_person_selection'][phx-value-id='#{person.id}']")
    |> render_click()

    view |> element("#bulk-delete-button") |> render_click()
    assert has_element?(view, "[phx-click='confirm_bulk_delete']")

    view |> element("[phx-click='cancel_bulk_delete']") |> render_click()
    refute has_element?(view, "[phx-click='confirm_bulk_delete']")
  end

  # ── bulk delete with partial failures ────────────────────────────────────

  test "confirm_bulk_delete shows partial failure message when some IDs are already gone",
       %{conn: conn} do
    person = person_fixture()
    {:ok, view, _html} = live(conn, ~p"/bo/people")

    view
    |> element("[phx-click='toggle_person_selection'][phx-value-id='#{person.id}']")
    |> render_click()

    # Delete externally so bulk_delete reports it in failed_ids
    {:ok, _} = People.delete_person(People.get_person(person.id))

    view |> element("#bulk-delete-button") |> render_click()
    view |> element("[phx-click='confirm_bulk_delete']") |> render_click()

    assert render(view) =~ "Failed:"
  end

  # ── validate channel in edit mode ─────────────────────────────────────────

  test "validate channel in edit mode uses update_changeset", %{conn: conn} do
    person = person_fixture()
    channel = channel_fixture(person, %{"channel_identifier" => "@validate-edit"})
    person = People.get_person_with_channels!(person.id)
    {:ok, view, _html} = live(conn, ~p"/bo/people")

    view
    |> element("[phx-click='select_person'][phx-value-id='#{person.id}']")
    |> render_click()

    view
    |> element(
      "[phx-click='open_modal'][phx-value-action='edit'][phx-value-entity='channel'][phx-value-id='#{channel.id}']"
    )
    |> render_click()

    view
    |> form("#channel-modal-form", %{"channel" => %{"channel_identifier" => ""}})
    |> render_change()

    assert has_element?(view, "#people-modal-overlay")
  end

  # ── validate team in edit mode ────────────────────────────────────────────

  test "validate team in edit mode uses update_changeset", %{conn: conn} do
    team = team_fixture(%{name: "ValidateEditTeam#{System.unique_integer([:positive])}"})
    {:ok, view, _html} = live(conn, ~p"/bo/people")

    view |> element("[phx-value-tab='teams']") |> render_click()

    view
    |> element(
      "[phx-click='open_modal'][phx-value-action='edit'][phx-value-entity='team'][phx-value-id='#{team.id}']"
    )
    |> render_click()

    view
    |> form("#team-modal-form", %{"team" => %{"name" => ""}})
    |> render_change()

    assert has_element?(view, "#people-modal-overlay")
  end

  # ── save team with invalid data ───────────────────────────────────────────

  test "save team with blank name keeps modal open with validation error", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/people")

    view |> element("[phx-value-tab='teams']") |> render_click()
    view |> element("#new-team-button") |> render_click()

    view
    |> form("#team-modal-form", %{"team" => %{"name" => ""}})
    |> render_submit()

    assert has_element?(view, "#people-modal-overlay")
  end

  # ── create_and_assign_team error branch ──────────────────────────────────

  test "create_and_assign_team shows error flash when team name is already taken", %{conn: conn} do
    ts = System.unique_integer([:positive])
    _existing = team_fixture(%{name: "DupTeam#{ts}"})
    person = person_fixture()
    {:ok, view, _html} = live(conn, ~p"/bo/people")

    view
    |> element("[phx-click='select_person'][phx-value-id='#{person.id}']")
    |> render_click()

    render_hook(view, "create_and_assign_team", %{"name" => "DupTeam#{ts}"})

    assert render(view) =~ "Failed to create team"
  end

  # ── template: team description ────────────────────────────────────────────

  test "teams tab renders team description when present", %{conn: conn} do
    ts = System.unique_integer([:positive])
    _team = team_fixture(%{name: "DescTeam#{ts}", description: "Description text #{ts}"})
    {:ok, view, _html} = live(conn, ~p"/bo/people")

    view |> element("[phx-value-tab='teams']") |> render_click()

    assert render(view) =~ "Description text #{ts}"
  end

  # ── template: channel dm_channel_id ──────────────────────────────────────

  test "person detail shows dm_channel_id for mattermost channel", %{conn: conn} do
    ts = System.unique_integer([:positive])
    person = person_fixture()

    channel_fixture(person, %{
      "platform" => "mattermost",
      "channel_identifier" => "@mm-#{ts}",
      "dm_channel_id" => "dm-#{ts}"
    })

    person = People.get_person_with_channels!(person.id)
    {:ok, view, _html} = live(conn, ~p"/bo/people")

    view
    |> element("[phx-click='select_person'][phx-value-id='#{person.id}']")
    |> render_click()

    assert render(view) =~ "dm-#{ts}"
  end

  # ── template: person email validation error ───────────────────────────────

  test "person form shows email uniqueness error on duplicate email", %{conn: conn} do
    ts = System.unique_integer([:positive])
    email = "dup#{ts}@example.com"
    _existing = person_fixture(%{"email" => email})
    {:ok, view, _html} = live(conn, ~p"/bo/people")

    view |> element("#new-person-button") |> render_click()

    view
    |> form("#person-modal-form", %{
      "person" => %{"full_name" => "Dup Email Person", "email" => email}
    })
    |> render_submit()

    assert has_element?(view, "#people-modal-overlay")
    assert render(view) =~ "has already been taken"
  end

  # ── template: mattermost DM channel field ────────────────────────────────

  test "add channel form shows DM channel ID field when platform is mattermost", %{conn: conn} do
    person = person_fixture()
    {:ok, view, _html} = live(conn, ~p"/bo/people")

    view
    |> element("[phx-click='select_person'][phx-value-id='#{person.id}']")
    |> render_click()

    view |> element("#add-channel-button") |> render_click()

    view
    |> form("#channel-modal-form", %{
      "channel" => %{"platform" => "mattermost", "channel_identifier" => "@mm"}
    })
    |> render_change()

    assert render(view) =~ "DM Channel ID"
  end

  # ── template: merge candidates list ──────────────────────────────────────

  test "merge_search renders candidate list with name and email", %{conn: conn} do
    ts = System.unique_integer([:positive])
    survivor = person_fixture(%{"full_name" => "MergeSurvivor#{ts}"})

    candidate =
      person_fixture(%{
        "full_name" => "MergeCandidate#{ts}",
        "email" => "mc#{ts}@example.com"
      })

    {:ok, view, _html} = live(conn, ~p"/bo/people")

    view
    |> element("[phx-click='select_person'][phx-value-id='#{survivor.id}']")
    |> render_click()

    view
    |> element("[phx-click='open_merge_modal'][phx-value-id='#{survivor.id}']")
    |> render_click()

    view
    |> form("[phx-change='merge_search']", %{"merge_search" => "MergeCandidate#{ts}"})
    |> render_change()

    html = render(view)
    assert html =~ candidate.full_name
    assert html =~ "mc#{ts}@example.com"
  end

  test "merge modal can search survivor candidates when opened from incomplete row", %{conn: conn} do
    ts = System.unique_integer([:positive])
    loser = person_fixture(%{"full_name" => "MergeLoser#{ts}"})

    survivor =
      person_fixture(%{
        "full_name" => "MergeKeep#{ts}",
        "email" => "keep#{ts}@example.com"
      })

    {:ok, view, _html} = live(conn, ~p"/bo/people")

    render_click(view, "open_merge_modal", %{
      "id" => to_string(loser.id),
      "role" => "loser"
    })

    view
    |> form("[phx-change='merge_search']", %{"merge_search" => "MergeKeep#{ts}"})
    |> render_change()

    html = render(view)
    assert html =~ survivor.full_name
    assert html =~ "keep#{ts}@example.com"
  end

  # ── timezone rendering ────────────────────────────────────────────────────

  test "channel last_interaction_at timestamps are shifted by configured timezone", %{conn: conn} do
    person = person_fixture()
    known = ~U[2026-06-15 12:00:00Z]

    channel_fixture(person, %{
      "platform" => "slack",
      "channel_identifier" => "@tz-check",
      "last_interaction_at" => known
    })

    Zaq.TimezoneTestHelpers.stub_system_timezone("GMT+03:00")

    {:ok, view, _html} = live(conn, ~p"/bo/people")

    view
    |> element("[phx-click='select_person'][phx-value-id='#{person.id}']")
    |> render_click()

    html = render(view)
    assert html =~ "last seen"
    assert html =~ "15:00"
  end

  # ── switch_tab resets selected person ────────────────────────────────────

  test "switching to People tab after Teams clears selected state", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/people")

    view |> element("[phx-value-tab='teams']") |> render_click()
    view |> element("[phx-value-tab='people']") |> render_click()

    state = :sys.get_state(view.pid)
    assert state.socket.assigns.active_tab == :people
    assert state.socket.assigns.selected_person == nil
  end

  defp insert_channel_config(attrs) do
    params =
      %{
        name: "Mattermost Main",
        provider: "mattermost",
        kind: "retrieval",
        url: "https://mattermost.local",
        token: "test-token",
        enabled: true
      }
      |> Map.merge(attrs)

    %ChannelConfig{}
    |> ChannelConfig.changeset(params)
    |> Repo.insert!()
  end

  defp insert_retrieval_channel(config, attrs) do
    params =
      %{
        channel_config_id: config.id,
        channel_id: "channel-#{System.unique_integer([:positive])}",
        channel_name: "engineering",
        team_id: "team-1",
        team_name: "Platform",
        active: true
      }
      |> Map.merge(attrs)

    %RetrievalChannel{}
    |> RetrievalChannel.changeset(params)
    |> Repo.insert!()
  end

  defp create_conversation_agent(conversation_enabled, name_suffix) do
    credential =
      ai_credential_fixture(%{
        provider: "openai",
        endpoint: "https://api.openai.com/v1",
        api_key: "x"
      })

    {:ok, agent} =
      Zaq.Agent.create_agent(%{
        name: "People #{name_suffix} #{System.unique_integer([:positive])}",
        description: "test",
        job: "You are a test agent",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        conversation_enabled: conversation_enabled,
        active: true,
        advanced_options: %{}
      })

    agent
  end
end
