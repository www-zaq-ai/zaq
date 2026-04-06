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

  test "new person button opens modal and creates person", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/people")

    view
    |> element("#new-person-button")
    |> render_click()

    assert has_element?(view, "#people-modal-overlay")
    assert has_element?(view, "#person-modal-form")
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

  test "add new channel button opens modal and creates channel", %{conn: conn} do
    {:ok, person} =
      People.create_person(%{
        "full_name" => "Modal Channel Owner",
        "email" => "channel.owner.#{System.unique_integer([:positive])}@example.com",
        "role" => "Ops",
        "status" => "active"
      })

    {:ok, view, _html} = live(conn, ~p"/bo/people")

    view
    |> element("[phx-click='select_person'][phx-value-id='#{person.id}']")
    |> render_click()

    view
    |> element("#add-channel-button")
    |> render_click()

    assert has_element?(view, "#people-modal-overlay")
    assert has_element?(view, "#channel-modal-form")
    assert has_element?(view, "h3", "Add Channel")

    channel_identifier = "@modal-owner-#{System.unique_integer([:positive])}"

    view
    |> form("#channel-modal-form", %{
      "channel" => %{
        "platform" => "slack",
        "channel_identifier" => channel_identifier
      }
    })
    |> render_submit()

    assert render(view) =~ "slack"
    assert render(view) =~ channel_identifier
  end
end
