defmodule ZaqWeb.Dashboard.MetricOverviewTest do
  use ZaqWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Zaq.Engine.Telemetry.Contracts.{DisplayMeta, RuntimeMeta}
  alias Zaq.Engine.Telemetry.Contracts.Payloads.ScalarPayload
  alias ZaqWeb.Dashboard.MetricOverview

  test "metric_overview/1 renders metrics without secondary links for unknown metric ids" do
    html =
      render_component(&MetricOverview.metric_overview/1,
        metric_cards: [
          %ScalarPayload{
            id: "dashboard-metric-active-users",
            label: "Active users",
            value: 42,
            display: %DisplayMeta{range: "24h"},
            runtime: %RuntimeMeta{href: "/bo/users"}
          }
        ]
      )

    assert html =~ ~s(id="dashboard-metric-active-users")
    assert html =~ ~s(href="/bo/users")
    assert html =~ ~s(id="dashboard-metric-active-users-card")
    assert html =~ "Active users"
    assert html =~ "range: 24h"

    refute html =~ "dashboard-knowledge-base-metrics-link"
    refute html =~ "dashboard-llm-performance-link"
    refute html =~ "dashboard-conversations-metrics-link"
    refute html =~ "View Knowledge base metrics"
    refute html =~ "View LLM performance"
    refute html =~ "View Conversations metrics"
    refute html =~ "space-y-2"
  end
end
