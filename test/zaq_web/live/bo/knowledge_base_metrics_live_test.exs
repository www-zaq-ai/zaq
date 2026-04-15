defmodule ZaqWeb.Live.BO.KnowledgeBaseMetricsLiveTest do
  use ZaqWeb.ConnCase

  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures

  alias Zaq.Accounts

  setup %{conn: conn} do
    user = user_fixture(%{username: "knowledge_base_metrics_admin"})
    {:ok, user} = Accounts.change_password(user, %{password: "StrongPass1!"})

    %{conn: init_test_session(conn, %{user_id: user.id})}
  end

  test "renders knowledge base metrics cards and charts", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/dashboard/knowledge-base-metrics")

    assert has_element?(view, "#knowledge-base-metrics-page")
    assert has_element?(view, "#knowledge-base-metrics-total-chunks-card")
    assert has_element?(view, "#knowledge-base-metrics-average-chunks-card")
    assert has_element?(view, "#knowledge-base-metrics-ingestion-volume-chart")
    assert has_element?(view, "#knowledge-base-metrics-success-rate-chart")
  end

  test "set_range updates selected range", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/dashboard/knowledge-base-metrics")

    view
    |> element("#knowledge-base-metrics-range-30d")
    |> render_click()

    assert has_element?(view, "#knowledge-base-metrics-selected-range", "30d")
    assert has_element?(view, "#knowledge-base-metrics-range-30d[data-active='true']")
  end

  test "set_range ignores unsupported range values", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/dashboard/knowledge-base-metrics")

    assert has_element?(view, "#knowledge-base-metrics-selected-range", "7d")

    render_click(view, "set_range", %{"range" => "invalid"})

    assert has_element?(view, "#knowledge-base-metrics-selected-range", "7d")
    assert has_element?(view, "#knowledge-base-metrics-range-7d[data-active='true']")
  end

  test "refresh timer message reassigns telemetry state", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/dashboard/knowledge-base-metrics")

    send(view.pid, :refresh_telemetry)

    assert render(view) =~ "Knowledge Base Metrics"
    assert has_element?(view, "#knowledge-base-metrics-total-chunks-card")
    assert has_element?(view, "#knowledge-base-metrics-average-chunks-card")
  end

  test "can switch through every supported range", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/dashboard/knowledge-base-metrics")

    for range <- ["24h", "7d", "30d", "90d"] do
      view
      |> element("#knowledge-base-metrics-range-#{range}")
      |> render_click()

      assert has_element?(view, "#knowledge-base-metrics-selected-range", range)
      assert has_element?(view, "#knowledge-base-metrics-range-#{range}[data-active='true']")
    end
  end
end
