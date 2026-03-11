# test/zaq_web/plugs/auth_test.exs

defmodule ZaqWeb.Plugs.AuthTest do
  use ZaqWeb.ConnCase

  import Zaq.AccountsFixtures

  alias Zaq.Accounts
  alias ZaqWeb.Plugs.Auth

  setup do
    user = user_fixture()
    {:ok, active_user} = Accounts.change_password(user, %{password: "StrongPass1!"})
    %{user: active_user}
  end

  test "assigns current_user when session has user_id", %{conn: conn, user: user} do
    conn =
      conn
      |> init_test_session(%{user_id: user.id})
      |> Auth.call(%{})

    assert conn.assigns.current_user.id == user.id
  end

  test "redirects to login when no user_id in session", %{conn: conn} do
    conn =
      conn
      |> init_test_session(%{})
      |> fetch_flash()
      |> Auth.call(%{})

    assert redirected_to(conn) == "/bo/login"
    assert conn.halted
  end

  test "redirects to change-password when must_change_password is true", %{conn: conn} do
    user = user_fixture()
    # user has must_change_password: true by default

    conn =
      conn
      |> init_test_session(%{user_id: user.id})
      |> Map.put(:request_path, "/bo/dashboard")
      |> Auth.call(%{})

    assert redirected_to(conn) == "/bo/change-password"
    assert conn.halted
  end

  test "allows access to change-password when must_change_password is true", %{conn: conn} do
    user = user_fixture()

    conn =
      conn
      |> init_test_session(%{user_id: user.id})
      |> Map.put(:request_path, "/bo/change-password")
      |> Auth.call(%{})

    assert conn.assigns.current_user.id == user.id
    refute conn.halted
  end
end
