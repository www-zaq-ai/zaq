defmodule ZaqWeb.BOSessionTest do
  use ExUnit.Case, async: true

  test "preserves an existing bootstrap browser binding" do
    bootstrap_browser = "test-bootstrap-browser"

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Test.init_test_session(%{bootstrap_browser: bootstrap_browser})

    conn = ZaqWeb.BOSession.bind_bootstrap_browser(conn)

    assert Plug.Conn.get_session(conn, :bootstrap_browser) == bootstrap_browser
  end
end
