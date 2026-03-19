defmodule ZaqWeb.Live.BO.TelemetryPreviewLiveTest do
  use ZaqWeb.ConnCase

  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures

  alias Zaq.Accounts

  setup %{conn: conn} do
    user = user_fixture(%{username: "telemetry_admin"})
    {:ok, user} = Accounts.change_password(user, %{password: "StrongPass1!"})

    conn = init_test_session(conn, %{user_id: user.id})

    %{conn: conn, user: user}
  end

  test "renders telemetry preview page with stable sections", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/dashboard/telemetry-preview")

    assert has_element?(view, "#telemetry-preview-page")
    assert has_element?(view, "#telemetry-preview-controls")
    assert has_element?(view, "#telemetry-component-gallery")
    assert has_element?(view, "#telemetry-composed-dashboard")
    assert has_element?(view, "#range-7d[data-active='true']")
    assert has_element?(view, "#gallery-time-series-chart [data-tip-value]")
    assert has_element?(view, "#gallery-donut-chart [data-tip-value]")
    assert has_element?(view, "#gallery-radar-chart [data-tip-value]")
    assert has_element?(view, "#gallery-radar-chart [data-radar-color]")
  end

  test "set_range updates selected range", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/dashboard/telemetry-preview")

    view
    |> element("#range-30d")
    |> render_click()

    assert has_element?(view, "#selected-range", "30d")
    assert has_element?(view, "#range-30d[data-active='true']")
  end

  test "toggle_benchmark flips benchmark state", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/dashboard/telemetry-preview")

    assert has_element?(view, "#benchmark-state", "off")

    view
    |> element("#benchmark-toggle")
    |> render_click()

    assert has_element?(view, "#benchmark-state", "on")
    assert has_element?(view, "#composed-time-series-series-benchmark")
  end

  test "set_segment and set_feedback_scope update filters", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/dashboard/telemetry-preview")

    view
    |> element("#segment-geography")
    |> render_click()

    view
    |> element("#feedback-all")
    |> render_click()

    assert has_element?(view, "#selected-segment", "geography")
    assert has_element?(view, "#selected-feedback-scope", "all")
    assert has_element?(view, "#segment-geography[data-active='true']")
    assert has_element?(view, "#feedback-all[data-active='true']")
  end

  test "toggle_series hides and shows time-series legend entry", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/dashboard/telemetry-preview")

    assert has_element?(view, "#composed-time-series-series-latency")

    view
    |> element("#series-toggle-latency")
    |> render_click()

    refute has_element?(view, "#composed-time-series-series-latency")
    assert has_element?(view, "#series-toggle-latency[data-active='false']")

    view
    |> element("#series-toggle-latency")
    |> render_click()

    assert has_element?(view, "#composed-time-series-series-latency")
    assert has_element?(view, "#series-toggle-latency[data-active='true']")
  end
end
