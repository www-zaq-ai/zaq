defmodule ZaqWeb.Live.BO.Communication.HistoryLiveTest do
  use ZaqWeb.ConnCase

  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures

  alias Zaq.Accounts

  setup %{conn: conn} do
    user = user_fixture(%{username: "testadmin"})
    {:ok, user} = Accounts.change_password(user, %{password: "StrongPass1!"})

    conn = init_test_session(conn, %{user_id: user.id})

    %{conn: conn, user: user}
  end

  test "renders history placeholder", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/history")

    assert has_element?(view, "#history-page")
    assert render(view) =~ "Coming Soon"
  end
end
