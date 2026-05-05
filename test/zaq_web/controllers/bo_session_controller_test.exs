# test/zaq_web/controllers/bo_session_controller_test.exs

defmodule ZaqWeb.BOSessionControllerTest do
  use ZaqWeb.ConnCase

  import Zaq.AccountsFixtures
  alias Zaq.Accounts

  setup tags do
    if tags[:bootstrap_only] do
      %{}
    else
      role = role_fixture(%{name: "super_admin"})

      user =
        user_fixture(%{
          role: role,
          username: "testadmin"
        })

      {:ok, user} = Accounts.change_password(user, %{password: "ValidPass123!"})

      %{user: user}
    end
  end

  describe "POST /bo/session" do
    test "redirects to dashboard on valid credentials", %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/bo/session", %{
          "username" => user.username,
          "password" => "ValidPass123!"
        })

      assert redirected_to(conn) == ~p"/bo/dashboard"
      assert get_session(conn, :user_id) == user.id
    end

    test "redirects to change-password when must_change_password is true", %{conn: conn} do
      role = role_fixture(%{name: "admin"})
      new_user = user_fixture(%{role: role, username: "newuser"})

      Application.put_env(:zaq, :super_admin, username: "newuser", password: "envpass")

      conn =
        post(conn, ~p"/bo/session", %{
          "username" => new_user.username,
          "password" => "envpass"
        })

      assert redirected_to(conn) == ~p"/bo/change-password"
      assert get_session(conn, :user_id) == new_user.id

      on_exit(fn -> Application.delete_env(:zaq, :super_admin) end)
    end

    test "redirects back to login with error on invalid credentials", %{conn: conn} do
      conn =
        post(conn, ~p"/bo/session", %{
          "username" => "testadmin",
          "password" => "wrongpass"
        })

      assert redirected_to(conn) == ~p"/bo/login"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Invalid username or password"
    end

    test "redirects back to login with error for unknown user", %{conn: conn} do
      conn =
        post(conn, ~p"/bo/session", %{
          "username" => "nobody",
          "password" => "whatever"
        })

      assert redirected_to(conn) == ~p"/bo/login"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Invalid username or password"
    end
  end

  describe "DELETE /bo/session" do
    test "clears session and redirects to login", %{conn: conn, user: user} do
      conn =
        conn
        |> init_test_session(%{user_id: user.id})
        |> delete(~p"/bo/session")

      assert redirected_to(conn) == ~p"/bo/login"
      refute get_session(conn, :user_id)
    end
  end

  describe "GET /bo/bootstrap-login" do
    @tag :bootstrap_only
    test "sets session and redirects to change-password in bootstrap state", %{conn: conn} do
      admin = Accounts.get_user_by_username("admin")

      conn = get(conn, ~p"/bo/bootstrap-login")

      assert redirected_to(conn) == ~p"/bo/change-password"
      assert get_session(conn, :user_id) == admin.id
    end

    test "redirects to login when bootstrap state is not matched", %{conn: conn} do
      _user = user_fixture(%{username: "not_admin"})

      conn = get(conn, ~p"/bo/bootstrap-login")

      assert redirected_to(conn) == ~p"/bo/login"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Invalid username or password"
    end
  end
end
