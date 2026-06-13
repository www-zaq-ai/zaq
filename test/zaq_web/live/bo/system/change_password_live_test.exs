defmodule ZaqWeb.Live.BO.System.ChangePasswordLiveTest do
  use ZaqWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures

  alias Zaq.Accounts
  alias Zaq.Accounts.User
  alias Zaq.Repo

  setup do
    Zaq.PortalStubs.stub_portal_reachable()
    :ok
  end

  test "allows users with must_change_password to access change-password", %{conn: conn} do
    user = user_fixture(%{username: "must_change_password_user"})
    conn = init_test_session(conn, %{user_id: user.id})

    {:ok, view, _html} = live(conn, ~p"/bo/change-password")

    assert has_element?(view, "#change-password-form")
    assert has_element?(view, ~s(input[name="password"]))
    assert has_element?(view, ~s(input[name="password_confirmation"]))
    assert has_element?(view, "#password-requirements")
    assert has_element?(view, "#password-requirement-min_length", "At least 8 characters")
  end

  test "redirects users with must_change_password from dashboard to change-password", %{
    conn: conn
  } do
    user = user_fixture(%{username: "must_change_password_redirect_user"})
    conn = init_test_session(conn, %{user_id: user.id})

    assert {:error, {_, %{to: "/bo/change-password"}}} = live(conn, ~p"/bo/dashboard")
  end

  test "shows validation error when passwords do not match", %{conn: conn} do
    user = user_fixture(%{username: "must_change_password_mismatch"})
    conn = init_test_session(conn, %{user_id: user.id})

    {:ok, view, _html} = live(conn, ~p"/bo/change-password")

    view
    |> form("#change-password-form", %{
      "password" => "StrongPass1!",
      "password_confirmation" => "StrongPass2!"
    })
    |> render_submit()

    assert has_element?(view, "div.alert-error span", "Passwords do not match")
  end

  test "shows changeset error when new password is too short", %{conn: conn} do
    user = user_fixture(%{username: "must_change_password_short"})
    conn = init_test_session(conn, %{user_id: user.id})

    {:ok, view, _html} = live(conn, ~p"/bo/change-password")

    view
    |> form("#change-password-form", %{
      "password" => "short",
      "password_confirmation" => "short"
    })
    |> render_submit()

    render_click(view, "accept_portal_consent")

    assert has_element?(
             view,
             "div.alert-error span",
             "should be at least 8 character(s)"
           )
  end

  test "shows live checklist and confirmation feedback", %{conn: conn} do
    user = user_fixture(%{username: "must_change_password_live_feedback"})
    conn = init_test_session(conn, %{user_id: user.id})

    {:ok, view, _html} = live(conn, ~p"/bo/change-password")

    view
    |> form("#change-password-form", %{
      "password" => "StrongPass1",
      "password_confirmation" => "StrongPass1"
    })
    |> render_change()

    assert has_element?(view, "#password-requirement-symbol", "At least one special character")
    assert has_element?(view, "#password-confirmation-status", "Passwords match")
    assert has_element?(view, "button[type='submit'][disabled]")

    view
    |> form("#change-password-form", %{
      "password" => "StrongPass1!",
      "password_confirmation" => "StrongPass1!"
    })
    |> render_change()

    refute has_element?(view, "button[type='submit'][disabled]")
  end

  test "updates password and redirects to dashboard", %{conn: conn} do
    user = user_fixture(%{username: "must_change_password_success"})
    conn = init_test_session(conn, %{user_id: user.id})

    {:ok, view, _html} = live(conn, ~p"/bo/change-password")

    html =
      view
      |> form("#change-password-form", %{
        "password" => "StrongPass1!",
        "password_confirmation" => "StrongPass1!"
      })
      |> render_submit()

    assert html =~ "To create your ZAQ account..."

    render_click(view, "decline_portal_consent")
    assert_redirect(view, ~p"/bo/dashboard")

    updated_user = Accounts.get_user!(user.id)
    refute updated_user.must_change_password
    assert is_binary(updated_user.password_hash)
  end

  test "redirects to ingestion when the portal consent is accepted", %{conn: conn} do
    user = user_fixture(%{username: "must_change_password_accept_ingestion"})
    conn = init_test_session(conn, %{user_id: user.id})

    {:ok, view, _html} = live(conn, ~p"/bo/change-password")

    view
    |> form("#change-password-form", %{
      "password" => "StrongPass1!",
      "password_confirmation" => "StrongPass1!"
    })
    |> render_submit()

    render_click(view, "accept_portal_consent")
    render_click(view, "close_post_accept_modal")

    flash = assert_redirect(view, ~p"/bo/ingestion")
    assert flash["info"] =~ "drop your files"

    updated_user = Accounts.get_user!(user.id)
    refute updated_user.must_change_password
    assert updated_user.portal_consent == "accepted"
  end

  test "shows mandatory email field when user email is missing", %{conn: conn} do
    user = user_fixture(%{username: "must_change_password_missing_email"})
    Repo.update_all(from(u in User, where: u.id == ^user.id), set: [email: nil])
    conn = init_test_session(conn, %{user_id: user.id})

    {:ok, view, _html} = live(conn, ~p"/bo/change-password")

    assert has_element?(view, ~s(input[name="email"][required]))
  end

  test "rejects a blank email inline before showing the consent modal", %{conn: conn} do
    user = user_fixture(%{username: "must_change_password_blank_email"})
    Repo.update_all(from(u in User, where: u.id == ^user.id), set: [email: nil])
    conn = init_test_session(conn, %{user_id: user.id})

    {:ok, view, _html} = live(conn, ~p"/bo/change-password")

    view
    |> form("#change-password-form", %{
      "email" => "",
      "password" => "StrongPass1!",
      "password_confirmation" => "StrongPass1!"
    })
    |> render_submit()

    # Caught server-side up front: inline error, and the consent modal is not shown.
    assert has_element?(view, "div.alert-error span", "Email can't be blank")
    refute has_element?(view, ~s(button[phx-click="accept_portal_consent"]))

    # Nothing was persisted — the account still has no email.
    assert is_nil(Accounts.get_user!(user.id).email)
  end

  test "requires valid email when user email is missing", %{conn: conn} do
    user = user_fixture(%{username: "must_change_password_invalid_email"})
    Repo.update_all(from(u in User, where: u.id == ^user.id), set: [email: nil])
    conn = init_test_session(conn, %{user_id: user.id})

    {:ok, view, _html} = live(conn, ~p"/bo/change-password")

    view
    |> form("#change-password-form", %{
      "email" => "invalid-email",
      "password" => "StrongPass1!",
      "password_confirmation" => "StrongPass1!"
    })
    |> render_submit()

    render_click(view, "accept_portal_consent")

    assert has_element?(view, "div.alert-error span", "must be a valid email address")
  end

  test "updates password and email then redirects when email is missing", %{conn: conn} do
    user = user_fixture(%{username: "must_change_password_email_success"})
    Repo.update_all(from(u in User, where: u.id == ^user.id), set: [email: nil])
    conn = init_test_session(conn, %{user_id: user.id})

    {:ok, view, _html} = live(conn, ~p"/bo/change-password")

    view
    |> form("#change-password-form", %{
      "email" => "admin@zaq.local",
      "password" => "StrongPass1!",
      "password_confirmation" => "StrongPass1!"
    })
    |> render_submit()

    render_click(view, "decline_portal_consent")
    assert_redirect(view, ~p"/bo/dashboard")

    updated_user = Accounts.get_user!(user.id)
    assert updated_user.email == "admin@zaq.local"
    refute updated_user.must_change_password
  end

  test "skips consent popup and redirects when portal is unreachable", %{conn: conn} do
    Zaq.PortalStubs.stub_portal_unreachable()

    user = user_fixture(%{username: "must_change_password_portal_unreachable"})
    conn = init_test_session(conn, %{user_id: user.id})

    {:ok, view, _html} = live(conn, ~p"/bo/change-password")

    # Submitting redirects straight to the dashboard: no consent popup is shown.
    # (If the popup were rendered the view would stay put awaiting accept/decline.)
    view
    |> form("#change-password-form", %{
      "password" => "StrongPass1!",
      "password_confirmation" => "StrongPass1!"
    })
    |> render_submit()

    assert_redirect(view, ~p"/bo/dashboard")

    updated_user = Accounts.get_user!(user.id)
    refute updated_user.must_change_password
    assert is_binary(updated_user.password_hash)
    assert updated_user.portal_consent == "declined"

    # The keyless ZAQ Router provider is scaffolded so it is still listed.
    credential = Zaq.System.get_ai_provider_credential_by_name("ZAQ Router")
    assert credential.provider == "zaq_router"
    assert is_nil(credential.api_key)
  end

  test "shows portal provisioning failure and redirects after decline", %{conn: conn} do
    # Registration succeeds, but the portal provisioning call fails.
    Mox.stub(Zaq.UserPortal.ClientMock, :onboard_user, fn _email -> {:error, :econnrefused} end)

    user = user_fixture(%{username: "must_change_password_provision_fail"})
    conn = init_test_session(conn, %{user_id: user.id})

    {:ok, view, _html} = live(conn, ~p"/bo/change-password")

    view
    |> form("#change-password-form", %{
      "password" => "StrongPass1!",
      "password_confirmation" => "StrongPass1!"
    })
    |> render_submit()

    html = render_click(view, "accept_portal_consent")

    assert html =~ "Portal activation failed"
    assert has_element?(view, "[phx-click='decline_portal_consent']")

    render_click(view, "decline_portal_consent")
    assert_redirect(view, ~p"/bo/dashboard")

    updated_user = Accounts.get_user!(user.id)
    # Password changed (registration persisted), consent reverted so the dashboard
    # retry flow remains valid.
    refute updated_user.must_change_password
    assert updated_user.portal_consent == "declined"
  end

  test "allows email override after portal reports the original email is taken", %{conn: conn} do
    user =
      user_fixture(%{username: "must_change_password_email_conflict", email: "taken@zaq.local"})

    conn = init_test_session(conn, %{user_id: user.id})

    Mox.expect(Zaq.UserPortal.ClientMock, :onboard_user, fn "taken@zaq.local" ->
      {:error, {409, %{"message" => "This email already has a portal account."}}}
    end)

    Mox.expect(Zaq.UserPortal.ClientMock, :onboard_user, fn "fresh@zaq.local" ->
      {:ok, %{litellm_api_key: "sk-fresh-email-key"}}
    end)

    {:ok, view, _html} = live(conn, ~p"/bo/change-password")

    view
    |> form("#change-password-form", %{
      "password" => "StrongPass1!",
      "password_confirmation" => "StrongPass1!"
    })
    |> render_submit()

    html = render_click(view, "accept_portal_consent")

    assert html =~ "This email already has a portal account."
    assert html =~ "Please use a different email address."
    assert has_element?(view, "#portal-consent-email")

    view
    |> element("form[phx-change='portal_consent_email_change']")
    |> render_change(%{"email" => "fresh@zaq.local"})

    refute render(view) =~ "Please use a different email address."

    render_click(view, "accept_portal_consent")

    updated_user = Accounts.get_user!(user.id)
    refute updated_user.must_change_password
    assert updated_user.email == "fresh@zaq.local"
    assert updated_user.portal_consent == "accepted"
  end

  test "close consent modal clears pending modal state without changing the password", %{
    conn: conn
  } do
    user = user_fixture(%{username: "must_change_password_close_consent"})
    conn = init_test_session(conn, %{user_id: user.id})

    {:ok, view, _html} = live(conn, ~p"/bo/change-password")

    view
    |> form("#change-password-form", %{
      "password" => "StrongPass1!",
      "password_confirmation" => "StrongPass1!"
    })
    |> render_submit()

    assert has_element?(view, "[phx-click='accept_portal_consent']")

    html = render_click(view, "close_consent_modal")

    refute html =~ "To create your ZAQ account..."

    unchanged_user = Accounts.get_user!(user.id)
    assert unchanged_user.must_change_password
    assert is_nil(unchanged_user.password_hash)
  end
end
