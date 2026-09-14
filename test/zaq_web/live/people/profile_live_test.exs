defmodule ZaqWeb.Live.People.ProfileLiveTest do
  use ZaqWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Zaq.Accounts.{People, PeopleAuth, PeoplePermissions}
  alias ZaqWeb.Live.People.ProfileLive

  setup %{conn: conn} do
    {:ok, person} =
      People.create_person(%{
        full_name: "Self Person",
        email: "self-ui@example.test",
        phone: "123",
        role: "Engineer",
        metadata: %{"private" => "hidden-value"}
      })

    {:ok, _} = PeoplePermissions.grant(:all_people, :access_profile)
    {:ok, challenge} = PeopleAuth.issue_challenge(person, {127, 9, 1, 1})
    {:ok, %{token: token}} = PeopleAuth.verify_challenge(challenge.challenge_id, challenge.code)
    [channel] = People.list_person_channels(person.id)

    %{
      conn: init_test_session(conn, %{person_session_token: token}),
      person: person,
      token: token,
      channel: channel
    }
  end

  test "access-only profile reads all fields and forged submissions cannot edit", %{
    conn: conn,
    person: person,
    channel: channel,
    token: token
  } do
    {:ok, view, html} = live(conn, "/people/profile")

    for text <- [
          person.email,
          "Engineer",
          "123",
          "active",
          "No teams",
          "email",
          "Lower numbers are tried first"
        ],
        do: assert(html =~ text)

    refute html =~ "hidden-value"
    refute html =~ token
    refute has_element?(view, "#self-profile-form")
    refute has_element?(view, "form[phx-submit=save_channel]")

    assert render_submit(view, "save_profile", %{"profile" => %{"full_name" => "Forged"}}) =~
             "permission"

    assert render_submit(view, "save_channel", %{
             "channel_id" => channel.id,
             "channel" => %{"weight" => "6"}
           }) =~ "permission"

    assert People.get_person(person.id).full_name == person.full_name
    assert People.get_channel(channel.id).weight == channel.weight
  end

  test "authorized forms persist only full name and owned priority then reload sorted values", %{
    conn: conn,
    person: person,
    channel: channel
  } do
    {:ok, _} = PeoplePermissions.grant(:all_people, :edit_profile)
    {:ok, view, _} = live(conn, "/people/profile")

    assert view |> form("#self-profile-form", profile: %{full_name: "Updated"}) |> render_submit() =~
             "Profile saved"

    assert People.get_person(person.id).full_name == "Updated"

    assert view |> form("#channel-form-#{channel.id}", channel: %{weight: "8"}) |> render_submit() =~
             "Priority saved"

    assert People.get_channel(channel.id).weight == 8
    assert has_element?(view, "#channel_#{channel.id}_weight[value='8']")
    assert has_element?(view, "#profile_full_name[value='Updated']")
  end

  test "validation preserves input and success clears errors; unknown channel is controlled", %{
    conn: conn,
    channel: channel
  } do
    {:ok, _} = PeoplePermissions.grant(:all_people, :edit_profile)
    {:ok, view, _} = live(conn, "/people/profile")

    assert view
           |> form("#channel-form-#{channel.id}", channel: %{weight: "-1"})
           |> render_submit() =~ "greater than or equal to 0"

    assert has_element?(view, "#channel_#{channel.id}_weight[value='-1']")

    assert view |> form("#channel-form-#{channel.id}", channel: %{weight: "2"}) |> render_submit() =~
             "Priority saved"

    refute render(view) =~ "greater than or equal"

    assert render_submit(view, "save_channel", %{
             "channel_id" => "unknown",
             "channel" => %{"weight" => "1"}
           }) =~ "Channel not found"

    assert render_submit(view, "save_profile", %{}) =~ "Unable to save"
  end

  test "edit revocation is authoritative on next save and grant works after reload", %{
    conn: conn,
    person: person
  } do
    {:ok, _} = PeoplePermissions.grant(:all_people, :edit_profile)
    {:ok, view, _} = live(conn, "/people/profile")
    {:ok, _} = PeoplePermissions.revoke(:all_people, :edit_profile)

    assert view |> form("#self-profile-form", profile: %{full_name: "Revoked"}) |> render_submit() =~
             "permission"

    refute has_element?(view, "#self-profile-form")
    assert People.get_person(person.id).full_name == person.full_name
    {:ok, _} = PeoplePermissions.grant(:all_people, :edit_profile)
    {:ok, view, _} = live(conn, "/people/profile")
    assert has_element?(view, "#self-profile-form")
    {:ok, _} = PeoplePermissions.revoke(:all_people, :access_profile)
    render_submit(view, "save_profile", %{"profile" => %{"full_name" => "Denied"}})
    assert_redirect(view, "/people/login")
  end

  test "empty optional fields and channels display fallbacks", %{
    conn: conn,
    person: person,
    channel: channel
  } do
    {:ok, _} = People.update_person(person, %{email: nil, phone: nil, role: nil})
    {:ok, _} = People.delete_channel(channel)
    {:ok, _, html} = live(conn, "/people/profile")
    assert html =~ "Not provided"
    assert html =~ "No channels"
  end

  test "invalid config fails closed with visible unavailable feedback", %{conn: conn} do
    {:ok, _} = PeoplePermissions.grant(:all_people, :edit_profile)
    {:ok, view, _} = live(conn, "/people/profile")
    Zaq.System.set_config("people_access.session_lifetime_seconds", "broken")
    render_submit(view, "save_profile", %{"profile" => %{"full_name" => "Denied"}})
    assert_redirect(view, "/people/login")
    response = get(conn, "/people/profile")
    assert Phoenix.Flash.get(response.assigns.flash, :error) =~ "unavailable"
  end

  test "crafted non-scalar fields and malformed channel coordinates produce controlled errors", %{
    conn: conn,
    person: person,
    channel: channel
  } do
    {:ok, _} = PeoplePermissions.grant(:all_people, :edit_profile)
    {:ok, view, _} = live(conn, "/people/profile")

    assert render_submit(view, "save_profile", %{"profile" => %{"full_name" => %{"bad" => true}}}) =~
             "is invalid"

    assert has_element?(view, "#profile_full_name[value='Self Person']")

    assert render_submit(view, "save_channel", %{
             "channel_id" => channel.id,
             "channel" => %{"weight" => %{"bad" => true}}
           }) =~ "is invalid"

    assert render_submit(view, "save_channel", %{"channel_id" => %{}, "channel" => %{}}) =~
             "Unable to save"

    assert People.get_person(person.id).full_name == person.full_name
  end

  test "profile callback fails closed when authority changes after the generic auth hook", %{
    token: token
  } do
    {:ok, _} = PeoplePermissions.grant(:all_people, :edit_profile)
    socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, flash: %{}}}

    {:ok, mounted} =
      ProfileLive.mount(%{}, %{"person_session_token" => token}, socket)

    {:ok, _} = PeopleAuth.revoke_session(token)

    assert {:noreply, denied} =
             ProfileLive.handle_event(
               "save_profile",
               %{"profile" => %{"full_name" => "Denied"}},
               mounted
             )

    assert denied.redirected == {:redirect, %{status: 302, to: "/people/login"}}
    assert {:ok, denied_mount} = ProfileLive.mount(%{}, %{}, socket)
    assert denied_mount.redirected == {:redirect, %{status: 302, to: "/people/login"}}
  end

  test "profile unavailable callbacks remove controls and retry reloads current authority", %{
    token: token
  } do
    socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, flash: %{}}}
    {:ok, _} = Zaq.System.set_config("people_access.session_lifetime_seconds", "broken")

    {:ok, unavailable} =
      ProfileLive.mount(%{}, %{"person_session_token" => token}, socket)

    assert unavailable.assigns.profile == nil
    refute unavailable.assigns.editable

    assert Phoenix.LiveViewTest.rendered_to_string(ProfileLive.render(unavailable.assigns)) =~
             "Retry"

    {:ok, _} = Zaq.System.set_config("people_access.session_lifetime_seconds", "604800")
    {:noreply, loaded} = ProfileLive.handle_event("retry", %{}, unavailable)
    assert loaded.assigns.profile.person.full_name == "Self Person"
    {:ok, _} = Zaq.System.set_config("people_access.session_lifetime_seconds", "broken")

    {:noreply, unavailable} =
      ProfileLive.handle_event(
        "save_profile",
        %{"profile" => %{"full_name" => "Denied"}},
        loaded
      )

    assert unavailable.assigns.profile == nil
  end
end
