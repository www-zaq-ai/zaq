defmodule ZaqWeb.RouterTest do
  use ZaqWeb.ConnCase

  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures
  import Mox

  alias Zaq.Accounts

  setup %{conn: conn} do
    stub(Zaq.NodeRouterMock, :find_node, fn _supervisor -> :channels@localhost end)

    user = user_fixture(%{email: "router-admin@example.com", username: "router_admin"})
    {:ok, user} = Accounts.change_password(user, %{password: "StrongPass1!"})
    authed_conn = init_test_session(conn, %{user_id: user.id})
    %{conn: conn, authed_conn: authed_conn}
  end

  test "knowledge-gap live route mounts", %{authed_conn: conn} do
    assert {:ok, _view, html} = live(conn, ~p"/bo/knowledge-gap")
    assert html =~ "Knowledge Gap"
  end

  test "channels ingestion provider live route mounts", %{authed_conn: conn} do
    assert {:ok, _view, html} = live(conn, ~p"/bo/channels/ingestion/slack")
    assert html =~ "Channels"
  end

  test "studio route is wired", %{authed_conn: conn} do
    conn = get(conn, "/bo/studio")
    refute conn.status == 404
  end
end
