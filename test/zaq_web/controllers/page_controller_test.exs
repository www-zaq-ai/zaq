# test/zaq_web/controllers/page_controller_test.exs

defmodule ZaqWeb.PageControllerTest do
  use ZaqWeb.ConnCase

  import Zaq.AccountsFixtures

  test "redirects to /bo/login when not logged in", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == ~p"/bo/login"
  end

  test "redirects to /bo/dashboard when logged in", %{conn: conn} do
    user = user_fixture()

    conn =
      conn
      |> init_test_session(%{user_id: user.id})
      |> get(~p"/")

    assert redirected_to(conn) == ~p"/bo/dashboard"
  end
end
