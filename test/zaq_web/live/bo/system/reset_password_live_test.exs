defmodule ZaqWeb.Live.BO.System.ResetPasswordLiveTest do
  use ZaqWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures

  alias Zaq.Accounts

  defp user_with_password do
    user = user_fixture()
    {:ok, user} = Accounts.change_password(user, %{password: "InitialPass1!"})
    user
  end

  describe "with a valid token" do
    test "renders the reset password form", %{conn: conn} do
      user = user_with_password()
      token = Accounts.generate_password_reset_token(user)

      {:ok, _lv, html} = live(conn, ~p"/bo/reset-password/#{token}")

      assert html =~ "Set New Password"
      assert html =~ user.username
    end

    test "resets password and redirects to login on valid submission", %{conn: conn} do
      user = user_with_password()
      token = Accounts.generate_password_reset_token(user)

      {:ok, lv, _html} = live(conn, ~p"/bo/reset-password/#{token}")

      {:ok, conn} =
        lv
        |> form("#reset-password-form", %{
          password: "BrandNew99!",
          password_confirmation: "BrandNew99!"
        })
        |> render_submit()
        |> follow_redirect(conn, ~p"/bo/login")

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Password reset successfully"
    end

    test "shows error when passwords do not match", %{conn: conn} do
      user = user_with_password()
      token = Accounts.generate_password_reset_token(user)

      {:ok, lv, _html} = live(conn, ~p"/bo/reset-password/#{token}")

      html =
        lv
        |> form("#reset-password-form", %{
          password: "BrandNew99!",
          password_confirmation: "Different99!"
        })
        |> render_submit()

      assert html =~ "Passwords do not match"
    end

    test "validate updates form feedback and clears stale errors", %{conn: conn} do
      user = user_with_password()
      token = Accounts.generate_password_reset_token(user)

      {:ok, lv, _html} = live(conn, ~p"/bo/reset-password/#{token}")

      _ =
        lv
        |> form("#reset-password-form", %{
          password: "BrandNew99!",
          password_confirmation: "Different99!"
        })
        |> render_submit()

      html =
        lv
        |> form("#reset-password-form", %{
          password: "BrandNew99!",
          password_confirmation: "BrandNew99!"
        })
        |> render_change()

      refute html =~ "Passwords do not match"
      assert html =~ "Set New Password"
    end

    test "shows formatted changeset errors for invalid password", %{conn: conn} do
      user = user_with_password()
      token = Accounts.generate_password_reset_token(user)

      {:ok, lv, _html} = live(conn, ~p"/bo/reset-password/#{token}")

      html =
        lv
        |> form("#reset-password-form", %{
          password: "weak",
          password_confirmation: "weak"
        })
        |> render_submit()

      assert html =~ "password"
    end
  end

  describe "with an invalid token" do
    test "renders the expired link page", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/bo/reset-password/invalid_token_here")

      assert html =~ "Link Expired"
      assert html =~ "Request a new link"
    end
  end

  describe "with an already-used token" do
    test "renders expired page after password has been changed", %{conn: conn} do
      user = user_with_password()
      token = Accounts.generate_password_reset_token(user)

      # Use the token once
      {:ok, _} = Accounts.change_password(user, %{password: "AlreadyChanged1!"})

      # Now try to reuse
      {:ok, _lv, html} = live(conn, ~p"/bo/reset-password/#{token}")

      assert html =~ "Link Expired"
    end
  end
end
