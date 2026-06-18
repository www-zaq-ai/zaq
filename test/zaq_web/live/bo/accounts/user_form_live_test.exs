defmodule ZaqWeb.Live.BO.Accounts.UserFormLiveTest do
  use ZaqWeb.ConnCase

  import Mox
  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures

  alias Zaq.Accounts
  alias Zaq.Accounts.User
  alias Zaq.Repo

  setup %{conn: conn} do
    admin = user_fixture(%{username: "user_form_admin"})
    {:ok, admin} = Accounts.change_password(admin, %{password: "StrongPass1!"})

    conn = init_test_session(conn, %{user_id: admin.id})

    %{conn: conn, admin: admin}
  end

  test "validates required fields on new form", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/users/new")

    view
    |> form("form[phx-submit='save']", user: %{username: "", password: "", role_id: ""})
    |> render_change()

    assert has_element?(view, "p", "can't be blank")
  end

  test "shows password policy feedback while validating new user password", %{conn: conn} do
    role = role_fixture(%{name: "lane6_new_password_feedback"})
    {:ok, view, _html} = live(conn, ~p"/bo/users/new")

    view
    |> form("form[phx-submit='save']",
      user: %{username: "lane6_new_feedback", password: "weak", role_id: role.id}
    )
    |> render_change()

    assert has_element?(view, "li", "At least 8 characters")
    assert has_element?(view, "li", "At least one uppercase letter")
  end

  test "creates a user and redirects", %{conn: conn} do
    role = role_fixture(%{name: "lane6_staff"})

    {:ok, view, _html} = live(conn, ~p"/bo/users/new")

    view
    |> form("form[phx-submit='save']",
      user: %{
        username: "lane6_user",
        email: "lane6@example.com",
        password: "StrongPass1!",
        role_id: role.id
      }
    )
    |> render_submit()

    assert_redirect(view, ~p"/bo/users")

    created = Accounts.get_user_by_username("lane6_user")
    assert created
    assert created.role_id == role.id
  end

  test "edits a user without requiring password", %{conn: conn} do
    role = role_fixture(%{name: "lane6_editor"})
    user = user_fixture(%{username: "lane6_edit_me", role: role})

    {:ok, view, _html} = live(conn, ~p"/bo/users/#{user.id}/edit")

    refute has_element?(view, "#password-change-fieldset")

    view
    |> form("form[phx-submit='save']",
      user: %{username: "lane6_edited", role_id: role.id}
    )
    |> render_submit()

    assert_redirect(view, ~p"/bo/users")
    assert Accounts.get_user!(user.id).username == "lane6_edited"
  end

  test "allows user to change own password from dedicated fieldset", %{conn: conn, admin: admin} do
    {:ok, view, _html} = live(conn, ~p"/bo/users/#{admin.id}/edit")

    view
    |> element("#toggle-password-edit")
    |> render_click()

    assert has_element?(view, "#password-change-fieldset")

    view
    |> form("form[phx-submit='save_password_change']",
      password_change: %{
        current_password: "StrongPass1!",
        new_password: "NextStrong1!",
        new_password_confirmation: "NextStrong1!"
      }
    )
    |> render_submit()

    refute has_element?(view, "#password-change-fieldset")
    assert {:ok, _user} = Accounts.authenticate_user(admin.username, "NextStrong1!")
  end

  test "validates password change feedback before save", %{conn: conn, admin: admin} do
    {:ok, view, _html} = live(conn, ~p"/bo/users/#{admin.id}/edit")

    view
    |> element("#toggle-password-edit")
    |> render_click()

    view
    |> form("form[phx-submit='save_password_change']",
      password_change: %{
        current_password: "StrongPass1!",
        new_password: "NextStrong1!",
        new_password_confirmation: "Mismatch1!"
      }
    )
    |> render_change()

    assert has_element?(view, "#password-change-confirmation-status", "Passwords do not match")
    assert has_element?(view, "#save-password-change[disabled]")

    view
    |> form("form[phx-submit='save_password_change']",
      password_change: %{
        current_password: "StrongPass1!",
        new_password: "NextStrong1!",
        new_password_confirmation: "NextStrong1!"
      }
    )
    |> render_change()

    assert has_element?(view, "#password-change-confirmation-status", "Passwords match")
    refute has_element?(view, "#save-password-change[disabled]")
  end

  test "can cancel the password change fieldset", %{conn: conn, admin: admin} do
    {:ok, view, _html} = live(conn, ~p"/bo/users/#{admin.id}/edit")

    view
    |> element("#toggle-password-edit")
    |> render_click()

    assert has_element?(view, "#password-change-fieldset")

    view
    |> element("#cancel-password-change")
    |> render_click()

    refute has_element?(view, "#password-change-fieldset")
  end

  test "rejects password change when editing another user", %{conn: conn} do
    role = role_fixture(%{name: "lane6_target_role"})
    target = user_fixture(%{username: "lane6_target_user", role: role})
    {:ok, _target} = Accounts.change_password(target, %{password: "TargetPass1!"})

    {:ok, view, _html} = live(conn, ~p"/bo/users/#{target.id}/edit")

    view
    |> element("#toggle-password-edit")
    |> render_click()

    view
    |> form("form[phx-submit='save_password_change']",
      password_change: %{
        current_password: "TargetPass1!",
        new_password: "AnotherStrong1!",
        new_password_confirmation: "AnotherStrong1!"
      }
    )
    |> render_submit()

    assert has_element?(view, "#password-change-error", "you can only change your own password")

    assert {:error, :invalid_password} =
             Accounts.authenticate_user(target.username, "AnotherStrong1!")
  end

  test "new save with invalid params stays on form", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/users/new")

    view
    |> form("form[phx-submit='save']", user: %{username: "", password: "", role_id: ""})
    |> render_submit()

    assert has_element?(view, "p", "can't be blank")
  end

  test "edit save with invalid params stays on form", %{conn: conn} do
    role = role_fixture(%{name: "lane6_user_edit_invalid_role"})
    user = user_fixture(%{username: "lane6_edit_invalid_user", role: role})

    {:ok, view, _html} = live(conn, ~p"/bo/users/#{user.id}/edit")

    view
    |> form("form[phx-submit='save']", user: %{username: "", role_id: ""})
    |> render_submit()

    assert has_element?(view, "p", "can't be blank")
  end

  describe "portal email sync on edit" do
    test "syncs email to portal when user has accepted consent and email changed", %{conn: conn} do
      role = role_fixture(%{name: "lane6_portal_sync_role"})
      user = user_fixture(%{username: "lane6_portal_sync", email: "old@example.com", role: role})
      {:ok, user} = Repo.update(User.portal_consent_changeset(user, "accepted"))

      expect(Zaq.UserPortal.ClientMock, :update_email, fn email, _api_key ->
        assert email == "new@example.com"
        :ok
      end)

      {:ok, view, _html} = live(conn, ~p"/bo/users/#{user.id}/edit")

      view
      |> form("form[phx-submit='save']",
        user: %{username: "lane6_portal_sync", email: "new@example.com", role_id: role.id}
      )
      |> render_submit()

      assert_redirect(view, ~p"/bo/users")
      verify!(Zaq.UserPortal.ClientMock)
    end

    test "does not call portal when email is unchanged", %{conn: conn} do
      role = role_fixture(%{name: "lane6_no_sync_role"})
      user = user_fixture(%{username: "lane6_no_sync", email: "same@example.com", role: role})
      {:ok, user} = Repo.update(User.portal_consent_changeset(user, "accepted"))

      stub(Zaq.UserPortal.ClientMock, :update_email, fn _email, _api_key ->
        flunk("update_email should not be called when email is unchanged")
      end)

      {:ok, view, _html} = live(conn, ~p"/bo/users/#{user.id}/edit")

      view
      |> form("form[phx-submit='save']",
        user: %{username: "lane6_no_sync_updated", email: "same@example.com", role_id: role.id}
      )
      |> render_submit()

      assert_redirect(view, ~p"/bo/users")
    end

    test "re-shows the activation banner (consent declined) on email change when the ZAQ Router has no key",
         %{conn: conn} do
      role = role_fixture(%{name: "lane6_banner_role"})
      user = user_fixture(%{username: "lane6_banner", email: "old@example.com", role: role})
      {:ok, user} = Repo.update(User.portal_consent_changeset(user, "accepted"))

      stub(Zaq.UserPortal.ClientMock, :update_email, fn _email, _api_key -> :ok end)

      {:ok, view, _html} = live(conn, ~p"/bo/users/#{user.id}/edit")

      view
      |> form("form[phx-submit='save']",
        user: %{username: "lane6_banner", email: "changed@example.com", role_id: role.id}
      )
      |> render_submit()

      assert_redirect(view, ~p"/bo/users")
      # No ZAQ Router key is set, so a new email re-activates the banner.
      assert Accounts.get_user!(user.id).portal_consent == "declined"
    end

    test "leaves consent untouched on email change when the ZAQ Router already has a key", %{
      conn: conn
    } do
      {:ok, _credential} =
        Zaq.System.create_ai_provider_credential(%{
          name: "ZAQ Router",
          provider: "zaq_router",
          endpoint: "http://localhost:4020",
          api_key: "sk-existing-key"
        })

      role = role_fixture(%{name: "lane6_keyset_role"})
      user = user_fixture(%{username: "lane6_keyset", email: "old@example.com", role: role})
      {:ok, user} = Repo.update(User.portal_consent_changeset(user, "accepted"))

      stub(Zaq.UserPortal.ClientMock, :update_email, fn _email, _api_key -> :ok end)

      {:ok, view, _html} = live(conn, ~p"/bo/users/#{user.id}/edit")

      view
      |> form("form[phx-submit='save']",
        user: %{username: "lane6_keyset", email: "changed@example.com", role_id: role.id}
      )
      |> render_submit()

      assert_redirect(view, ~p"/bo/users")
      assert Accounts.get_user!(user.id).portal_consent == "accepted"
    end

    test "does not call portal when user has not accepted consent", %{conn: conn} do
      role = role_fixture(%{name: "lane6_no_consent_role"})

      user =
        user_fixture(%{username: "lane6_no_consent", email: "before@example.com", role: role})

      stub(Zaq.UserPortal.ClientMock, :update_email, fn _email, _api_key ->
        flunk("update_email should not be called without consent")
      end)

      {:ok, view, _html} = live(conn, ~p"/bo/users/#{user.id}/edit")

      view
      |> form("form[phx-submit='save']",
        user: %{username: "lane6_no_consent", email: "after@example.com", role_id: role.id}
      )
      |> render_submit()

      assert_redirect(view, ~p"/bo/users")
    end
  end
end
