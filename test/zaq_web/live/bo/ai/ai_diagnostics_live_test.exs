defmodule ZaqWeb.Live.BO.AI.AIDiagnosticsLiveTest do
  use ZaqWeb.ConnCase

  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures

  alias Zaq.Accounts

  setup %{conn: conn} do
    user = user_fixture(%{username: "ai_diag_admin"})
    {:ok, user} = Accounts.change_password(user, %{password: "StrongPass1!"})

    conn = init_test_session(conn, %{user_id: user.id})

    %{conn: conn}
  end

  test "renders diagnostics and computes token estimator sample", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/ai-diagnostics")

    assert has_element?(view, "button[phx-click='test_llm']")
    assert has_element?(view, "button[phx-click='test_embedding']")
    assert has_element?(view, "button[phx-click='test_token_estimator']")
    assert has_element?(view, "a[href='/bo/prompt-templates']")

    view
    |> element("button[phx-click='test_token_estimator']")
    |> render_click()

    assert has_element?(view, "span", "12 tokens")
  end
end
