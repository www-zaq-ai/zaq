defmodule ZaqWeb.Live.BO.System.ChangePasswordLiveTest do
  use ZaqWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures

  alias Zaq.Accounts

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
  end
end
