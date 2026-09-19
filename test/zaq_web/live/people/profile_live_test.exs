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

    {:ok, _} = PeoplePermissions.grant(:everyone, :access_profile)
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
          "Your details, your teams, and how ZAQ can reach you.",
          "You’re not part of a team yet.",
          "email",
          "ZAQ sends notifications to your first contact channel. If delivery fails, ZAQ uses the next channel in this list."
        ],
        do: assert(html =~ text)

    refute html =~ "hidden-value"
    refute html =~ token
    refute html =~ "Prototype controls"
    refute html =~ "Review scenarios"
    refute html =~ "/bo/"
    assert has_element?(view, "#people-profile-menu", "Self Person")
    assert has_element?(view, ".zaq-person-header-heading #people-page-subtitle")
    assert has_element?(view, "#people-page-subtitle.hidden.sm\\:block")
    assert has_element?(view, "#people-settings-menu .zaq-toggle-group")
    assert has_element?(view, "#people-profile-menu .zaq-account-name.hidden.sm\\:inline")
    refute has_element?(view, "#people-header > .zaq-page-header-actions > .zaq-toggle-group")
    assert has_element?(view, ".zaq-pill.zaq-pill--success", "active")
    assert has_element?(view, "#information-heading", person.full_name)
    refute has_element?(view, "#information-heading + #edit-name[aria-label='Edit name']")

    assert has_element?(
             view,
             "section[aria-labelledby=information-heading].zaq-card-hover.zaq-border-default"
           )

    assert has_element?(
             view,
             "section[aria-labelledby=teams-heading].zaq-card-hover.zaq-border-default"
           )

    assert has_element?(view, "section[aria-labelledby=information-heading] dt.sr-only", "Email")
    assert has_element?(view, "section[aria-labelledby=information-heading] .hero-envelope")
    assert has_element?(view, "section[aria-labelledby=information-heading] dt.sr-only", "Phone")
    assert has_element?(view, "section[aria-labelledby=information-heading] .hero-phone")
    assert has_element?(view, "#people-profile-menu a[href='/people/profile']")
    assert has_element?(view, "#person-logout[action='/people/session']")
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
    {:ok, _} = PeoplePermissions.grant(:everyone, :edit_profile)

    {:ok, second} =
      People.add_channel(%{
        person_id: person.id,
        platform: "slack",
        channel_identifier: "ui-second"
      })

    {:ok, view, _} = live(conn, "/people/profile")
    refute has_element?(view, "#self-profile-form")
    assert has_element?(view, "#information-heading", "Self Person")
    assert has_element?(view, "#information-heading + #edit-name[aria-label='Edit name']")
    view |> element("#edit-name") |> render_click()
    assert has_element?(view, "#self-profile-form.zaq-layout-inline.items-start")
    assert has_element?(view, "#self-profile-form #profile-name")
    assert has_element?(view, "#self-profile-form .zaq-layout-inline.shrink-0.mt-5")
    assert has_element?(view, "#self-profile-form button[type=submit]", "Save name")
    assert has_element?(view, "#self-profile-form button[phx-click=cancel]", "Cancel")

    assert view |> form("#self-profile-form", profile: %{full_name: "Updated"}) |> render_submit() =~
             "Profile saved"

    assert People.get_person(person.id).full_name == "Updated"

    view |> element("#edit-order") |> render_click()

    assert has_element?(
             view,
             "#order-instructions",
             "Move your preferred contact channel to the top"
           )

    assert has_element?(view, "button[phx-click=save_order]", "Save preferences")

    assert has_element?(
             view,
             "#channel-priority-table tr[data-channel-id][tabindex='-1'] [data-drag-handle][draggable='true']"
           )

    view |> element("#channel-priority-#{second.id}-up") |> render_click()
    assert People.get_channel(channel.id).weight == 0

    assert view |> element("button[phx-click=save_order]") |> render_click() =~
             "Contact preferences saved"

    assert Enum.map(People.list_person_channels(person.id), &{&1.id, &1.weight}) == [
             {second.id, 0},
             {channel.id, 1}
           ]

    assert has_element?(view, "#people-profile-menu", "Updated")
    refute has_element?(view, "#self-profile-form")
  end

  test "stale order reloads current channels without overwriting concurrent priority", %{
    conn: conn,
    person: person,
    channel: channel
  } do
    {:ok, _} = PeoplePermissions.grant(:everyone, :edit_profile)

    {:ok, second} =
      People.add_channel(%{
        person_id: person.id,
        platform: "slack",
        channel_identifier: "ui-stale"
      })

    {:ok, view, _} = live(conn, "/people/profile")
    view |> element("#edit-order") |> render_click()
    render_click(view, "move_channel", %{"id" => to_string(second.id), "action" => "up"})
    {:ok, _} = People.update_self_channel_weight(person, channel.id, %{weight: 8})
    assert render_click(view, "save_order") =~ "changed since you started editing"
    assert People.get_channel(channel.id).weight == 8
    refute has_element?(view, "button[phx-click=save_order]")
    assert render_submit(view, "save_profile", %{}) =~ "Unable to save"
  end

  test "edit revocation is authoritative on next save and grant works after reload", %{
    conn: conn,
    person: person
  } do
    {:ok, _} = PeoplePermissions.grant(:everyone, :edit_profile)
    {:ok, view, _} = live(conn, "/people/profile")
    view |> element("#edit-name") |> render_click()
    {:ok, _} = PeoplePermissions.revoke(:everyone, :edit_profile)

    assert view |> form("#self-profile-form", profile: %{full_name: "Revoked"}) |> render_submit() =~
             "permission"

    refute has_element?(view, "#self-profile-form")
    assert People.get_person(person.id).full_name == person.full_name
    {:ok, _} = PeoplePermissions.grant(:everyone, :edit_profile)
    {:ok, view, _} = live(conn, "/people/profile")
    assert has_element?(view, "#edit-name")
    {:ok, _} = PeoplePermissions.revoke(:everyone, :access_profile)
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
    {:ok, _} = PeoplePermissions.grant(:everyone, :edit_profile)
    {:ok, view, _} = live(conn, "/people/profile")

    view |> element("#edit-name") |> render_click()
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
    {:ok, _} = PeoplePermissions.grant(:everyone, :edit_profile)
    {:ok, view, _} = live(conn, "/people/profile")
    view |> element("#edit-name") |> render_click()

    assert render_submit(view, "save_profile", %{"profile" => %{"full_name" => %{"bad" => true}}}) =~
             "is invalid"

    assert has_element?(view, "#profile-name[value='Self Person']")

    assert view
           |> form("#self-profile-form", profile: %{full_name: "Validated"})
           |> render_submit() =~ "Profile saved"

    refute render(view) =~ "is invalid"

    assert render_submit(view, "save_channel", %{
             "channel_id" => channel.id,
             "channel" => %{"weight" => %{"bad" => true}}
           }) =~ "Unable to save"

    assert render_submit(view, "save_channel", %{"channel_id" => %{}, "channel" => %{}}) =~
             "Unable to save"

    assert People.get_person(person.id).full_name == "Validated"
  end

  test "cancel and delayed events never persist; blank names keep existing optional validation",
       %{conn: conn, person: person} do
    {:ok, _} = PeoplePermissions.grant(:everyone, :edit_profile)
    {:ok, view, _} = live(conn, "/people/profile")
    render_click(view, "save_order")
    render_click(view, "move_channel", %{"id" => "bogus", "target" => %{}})
    view |> element("#edit-name") |> render_click()
    render_change(view, "validate_name", %{"profile" => %{"full_name" => "Discard me"}})
    render_click(view, "cancel")
    assert People.get_person(person.id).full_name == "Self Person"
    view |> element("#edit-name") |> render_click()
    assert has_element?(view, "#profile-name[value='Self Person']")

    assert view |> form("#self-profile-form", profile: %{full_name: " "}) |> render_submit() =~
             "Profile saved"

    assert People.get_person(person.id).full_name == ""
    assert has_element?(view, "#people-profile-menu", "Profile")
  end

  test "one editor at a time, invalid moves and cancel preserve saved priorities", %{
    conn: conn,
    person: person,
    channel: channel
  } do
    {:ok, _} = PeoplePermissions.grant(:everyone, :edit_profile)

    {:ok, second} =
      People.add_channel(%{
        person_id: person.id,
        platform: "microsoft_teams",
        channel_identifier: "teams-ui"
      })

    {:ok, z} = People.create_team(%{name: "Zulu"})
    {:ok, a} = People.create_team(%{name: "Alpha"})
    {:ok, _} = People.update_person(person, %{team_ids: [z.id, a.id]})
    {:ok, view, _} = live(conn, "/people/profile")
    assert has_element?(view, "section[aria-labelledby=teams-heading] li:first-child", "Alpha")
    refute has_element?(view, "section[aria-labelledby=teams-heading] button")

    assert has_element?(
             view,
             "#channel-priority-#{second.id} svg[class~='w-3.5'][class~='h-3.5']"
           )

    view |> element("#edit-order") |> render_click()
    assert has_element?(view, "#edit-name[disabled]")
    render_click(view, "edit_name")
    refute has_element?(view, "#self-profile-form")
    render_click(view, "move_channel", %{"id" => "bogus", "target" => %{}})
    view |> element("#channel-priority-#{second.id}-up") |> render_click()
    focus_id = "channel-priority-#{second.id}"
    assert_push_event(view, "profile-focus", %{id: ^focus_id})
    assert has_element?(view, "#channel-priority-table")
    assert has_element?(view, "#channel-priority tbody tr:first-child", "microsoft_teams")
    render_click(view, "cancel")
    assert_push_event(view, "profile-focus", %{id: "edit-order"})
    render_click(view, "save_order")
    render_click(view, "move_channel", %{"id" => to_string(second.id), "action" => "up"})
    assert Enum.map(People.list_person_channels(person.id), & &1.id) == [channel.id, second.id]
    view |> element("#edit-order") |> render_click()
    {:ok, _} = PeoplePermissions.revoke(:everyone, :edit_profile)

    assert render_click(view, "move_channel", %{"id" => to_string(second.id), "action" => "up"}) =~
             "permission"

    refute has_element?(view, "#edit-name")
    refute has_element?(view, "button[phx-click=save_order]")
  end

  test "single channel cannot open an order editor", %{
    conn: conn
  } do
    {:ok, _} = PeoplePermissions.grant(:everyone, :edit_profile)
    {:ok, view, _} = live(conn, "/people/profile")
    render_click(view, "edit_order")
    refute has_element?(view, "button[phx-click=save_order]")
  end

  test "gateway edit revocation and unavailable saves fail closed after the route hook", %{
    token: token
  } do
    {:ok, _} = PeoplePermissions.grant(:everyone, :edit_profile)
    socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, flash: %{}}}
    {:ok, mounted} = ProfileLive.mount(%{}, %{"person_session_token" => token}, socket)
    {:noreply, editing} = ProfileLive.handle_event("edit_name", %{}, mounted)

    {:noreply, invalid} =
      ProfileLive.handle_event("save_profile", %{"profile" => %{"full_name" => 123}}, editing)

    assert invalid.assigns.name_form[:full_name].value == 123
    assert invalid.assigns.name_errors == ["is invalid"]
    {:ok, _} = PeoplePermissions.revoke(:everyone, :edit_profile)

    {:noreply, denied} =
      ProfileLive.handle_event(
        "save_profile",
        %{"profile" => %{"full_name" => "Denied"}},
        editing
      )

    refute denied.assigns.editable
    assert denied.assigns.mode == :read
    {:ok, _} = PeoplePermissions.grant(:everyone, :edit_profile)
    {:noreply, editing} = ProfileLive.handle_event("edit_name", %{}, denied)
    {:ok, _} = Zaq.System.set_config("people_access.session_lifetime_seconds", "broken")

    {:noreply, unavailable} =
      ProfileLive.handle_event("save_profile", %{"profile" => %{"full_name" => "Draft"}}, editing)

    assert unavailable.assigns.profile == nil
    refute unavailable.assigns.editable
  end

  test "profile callback fails closed when authority changes after the generic auth hook", %{
    token: token
  } do
    {:ok, _} = PeoplePermissions.grant(:everyone, :edit_profile)
    socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, flash: %{}}}

    {:ok, mounted} =
      ProfileLive.mount(%{}, %{"person_session_token" => token}, socket)

    {:noreply, mounted} = ProfileLive.handle_event("edit_name", %{}, mounted)

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
