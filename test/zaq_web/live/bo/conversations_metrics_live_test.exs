defmodule ZaqWeb.Live.BO.ConversationsMetricsLiveTest do
  use ZaqWeb.ConnCase

  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures

  alias Zaq.Accounts

  setup %{conn: conn} do
    user = user_fixture(%{username: "conversations_metrics_admin"})
    {:ok, user} = Accounts.change_password(user, %{password: "StrongPass1!"})

    %{conn: init_test_session(conn, %{user_id: user.id})}
  end

  test "renders conversations metrics charts", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/dashboard/conversations-metrics")

    assert has_element?(view, "#conversations-metrics-page")
    assert has_element?(view, "#conversations-metrics-messages-received-chart")
    assert has_element?(view, "#conversations-metrics-messages-per-channel-chart")
    assert has_element?(view, "#conversations-metrics-confidence-distribution-chart")
    assert has_element?(view, "#conversations-metrics-no-answer-rate-chart")
    assert has_element?(view, "#conversations-metrics-average-response-time-chart")
  end

  test "set_range updates selected range", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/dashboard/conversations-metrics")

    view
    |> element("#conversations-metrics-range-30d")
    |> render_click()

    assert has_element?(view, "#conversations-metrics-selected-range", "30d")
    assert has_element?(view, "#conversations-metrics-range-30d[data-active='true']")
  end
end
