defmodule ZaqWeb.Live.BO.System.PeopleAccessConfigLiveTest do
  use ZaqWeb.ConnCase, async: false

  import Mox
  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures

  alias Zaq.System
  alias Zaq.System.PeopleAccessConfig

  setup :verify_on_exit!

  setup %{conn: conn} do
    user = user_fixture()
    {:ok, user} = Zaq.Accounts.change_password(user, %{password: "StrongPass1!"})
    %{conn: init_test_session(conn, %{user_id: user.id})}
  end

  test "navigation displays defaults without persistence, including seven days", %{conn: conn} do
    {:ok, view, _} = live(conn, "/bo/system-config")
    view |> element("button[phx-value-tab='people_access']") |> render_click()
    assert_patch(view, "/bo/system-config?tab=people_access")
    assert has_element?(view, "#people-access-config-form")

    assert has_element?(
             view,
             "#people_access_config_session_lifetime_seconds[value='604800'][step='1']"
           )

    assert render(view) =~ "7 days"
    assert System.get_config("people_access.session_lifetime_seconds") == nil
    render_patch(view, "/bo/system-config?tab=global")
    refute has_element?(view, "#people-access-config-form")
    render_patch(view, "/bo/system-config?tab=people_access")
    assert has_element?(view, "#people-access-config-form")
    render_patch(view, "/bo/system-config?tab=untrusted_people_access")
    refute has_element?(view, "#people-access-config-form")
  end

  test "save all fields and reload, validate immediately, preserve prior config on invalid submission",
       %{conn: conn} do
    {:ok, view, _} = live(conn, "/bo/system-config?tab=people_access")

    attrs =
      Map.new(Map.from_struct(%PeopleAccessConfig{}), fn {key, value} ->
        {Atom.to_string(key), to_string(value + 1)}
      end)

    assert view
           |> form("#people-access-config-form", people_access_config: attrs)
           |> render_submit() =~ "People access settings saved"

    assert {:ok, saved} = System.get_people_access_config()
    assert saved.session_lifetime_seconds == 604_801
    {:ok, view, _} = live(conn, "/bo/system-config?tab=people_access")
    assert has_element?(view, "#people_access_config_session_lifetime_seconds[value='604801']")
    invalid = Map.merge(attrs, %{"otp_max_attempts" => "0", "otp_send_ip_limit" => "99"})

    assert view
           |> form("#people-access-config-form", people_access_config: invalid)
           |> render_change() =~ "must be greater than 0"

    assert view
           |> form("#people-access-config-form", people_access_config: invalid)
           |> render_submit() =~ "must be greater than 0"

    assert has_element?(view, "#people_access_config_otp_send_ip_limit[value='99']")
    assert {:ok, ^saved} = System.get_people_access_config()
  end

  test "malicious values and invalid containers render errors rather than crash", %{conn: conn} do
    {:ok, view, _} = live(conn, "/bo/system-config?tab=people_access")

    for value <- [%{}, [], true, 1.0, "300junk", nil] do
      html =
        render_hook(view, "save_people_access_config", %{
          "people_access_config" => %{"otp_validity_seconds" => value}
        })

      assert html =~ "be blank"
    end

    assert render_submit(view, "save_people_access_config", %{}) =~ "must be a map of settings"

    assert render_hook(view, "validate_people_access_config", %{"people_access_config" => []}) =~
             "must be a map of settings"

    assert System.get_config("people_access.otp_validity_seconds") == nil
  end

  test "corrupt load is read-only, forged save blocked, retry reloads repaired settings", %{
    conn: conn
  } do
    System.set_config("people_access.otp_max_attempts", "broken")
    {:ok, view, html} = live(conn, "/bo/system-config?tab=people_access")
    assert html =~ "Stored People access settings are invalid"
    assert has_element?(view, "#people-access-save[disabled]")
    refute has_element?(view, "#people_access_config_session_lifetime_seconds")

    render_submit(view, "save_people_access_config", %{
      "people_access_config" => Map.from_struct(%PeopleAccessConfig{})
    })

    render_change(view, "validate_people_access_config", %{"people_access_config" => %{}})
    assert System.get_config("people_access.otp_max_attempts") == "broken"
    System.set_config("people_access.otp_max_attempts", "19")
    view |> element("#people-access-retry") |> render_click()
    assert has_element?(view, "#people_access_config_otp_max_attempts[value='19']")
    refute has_element?(view, "#people-access-save[disabled]")
  end

  test "unavailable load distinguishes failure from defaults and retry succeeds", %{conn: conn} do
    conn = put_session(conn, :system_config_node_router_module, Zaq.NodeRouterMock)

    stub(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{} = event ->
      case Keyword.fetch!(event.opts, :action) do
        :system_config_get_people_access_config -> %{event | response: {:error, :unavailable}}
        _ -> Zaq.NodeRouter.dispatch(event)
      end
    end)

    {:ok, view, html} = live(conn, "/bo/system-config?tab=people_access")
    assert html =~ "People access settings are unavailable"
    assert has_element?(view, "#people-access-save[disabled]")

    expect(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{
                                               opts: [
                                                 action: :system_config_get_people_access_config
                                               ]
                                             } = event ->
      Zaq.NodeRouter.dispatch(event)
    end)

    view |> element("#people-access-retry") |> render_click()
    assert has_element?(view, "#people_access_config_session_lifetime_seconds[value='604800']")
  end

  test "save transport failure retains edits for retry", %{conn: conn} do
    conn = put_session(conn, :system_config_node_router_module, Zaq.NodeRouterMock)

    stub(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{} = event ->
      case Keyword.fetch!(event.opts, :action) do
        :system_config_save_people_access_config -> %{event | response: {:error, :unavailable}}
        _ -> Zaq.NodeRouter.dispatch(event)
      end
    end)

    {:ok, view, _} = live(conn, "/bo/system-config?tab=people_access")

    html =
      view
      |> form("#people-access-config-form", people_access_config: %{otp_max_attempts: "77"})
      |> render_submit()

    assert html =~ "Could not save People access settings"
    assert has_element?(view, "#people_access_config_otp_max_attempts[value='77']")
    assert System.get_config("people_access.otp_max_attempts") == nil
  end
end
