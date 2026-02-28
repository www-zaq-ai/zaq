# test/zaq_web/plugs/auth_test.exs

defmodule ZaqWeb.Plugs.AuthTest do
  use ZaqWeb.ConnCase

  import Zaq.AccountsFixtures
  alias ZaqWeb.Plugs.Auth

  setup do
    user = user_fixture()
    %{user: user}
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
end
