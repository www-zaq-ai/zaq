defmodule ZaqWeb.Live.BO.LLMPerformanceLiveTest do
  use ZaqWeb.ConnCase

  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures

  alias Zaq.Accounts

  setup %{conn: conn} do
    user = user_fixture(%{username: "llm_perf_admin"})
    {:ok, user} = Accounts.change_password(user, %{password: "StrongPass1!"})

    %{conn: init_test_session(conn, %{user_id: user.id})}
  end

  test "renders llm performance charts", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/dashboard/llm-performance")

    assert has_element?(view, "#llm-performance-page")
    assert has_element?(view, "#llm-performance-api-calls-chart")
    assert has_element?(view, "#llm-performance-token-usage-chart")
    assert has_element?(view, "#llm-performance-retrieval-effectiveness")
  end

  test "set_range updates selected range", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/dashboard/llm-performance")

    view
    |> element("#llm-performance-range-30d")
    |> render_click()

    assert has_element?(view, "#llm-performance-selected-range", "30d")
    assert has_element?(view, "#llm-performance-range-30d[data-active='true']")
  end
end
