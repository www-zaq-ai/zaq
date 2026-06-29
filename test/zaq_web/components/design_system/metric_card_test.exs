defmodule ZaqWeb.Components.DesignSystem.MetricCardTest do
  use ZaqWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Zaq.Engine.Telemetry.Contracts.{DisplayMeta, RuntimeMeta}
  alias Zaq.Engine.Telemetry.Contracts.Payloads.ScalarPayload
  alias ZaqWeb.Components.DesignSystem.MetricCard

  test "metric_card/1 renders label, value, and id" do
    html =
      render_component(&MetricCard.metric_card/1,
        id: "metric-users",
        label: "Active users",
        value: 12_450,
        trend: 4.2,
        hint: "Last 24h"
      )

    assert html =~ "id=\"metric-users\""
    assert html =~ "Active users"
    assert html =~ "12,450"
    assert html =~ "+4.2%"
    assert html =~ "Last 24h"
  end

  test "metric_card/1 renders external primary_link with href" do
    html =
      render_component(&MetricCard.metric_card/1,
        id: "external-card",
        label: "Docs",
        value: 1,
        primary_link: %{
          id: "external-link",
          destination: "https://example.com/docs",
          external: true
        }
      )

    assert html =~ ~s(id="external-link")
    assert html =~ ~s(href="https://example.com/docs")
    refute html =~ ~s(data-phx-link="redirect")
  end

  test "metric_card/1 accepts DisplayMeta struct passed through meta" do
    html =
      render_component(&MetricCard.metric_card/1,
        id: "metric-display-meta",
        label: "Usage",
        value: 42,
        meta: %DisplayMeta{
          range: "7d",
          hint: "complete",
          extra: %{"owner_name" => "Ops", 42 => true, team_size: 12, empty: "", skipped: nil}
        }
      )

    assert html =~ "range: 7d"
    assert html =~ "complete"
    assert html =~ "team size: 12"
    assert html =~ "owner name: Ops"
    assert html =~ "42: true"
    refute html =~ "empty:"
    refute html =~ "skipped:"
  end

  test "metric_card/1 converts map meta into display metadata and ignores runtime href" do
    html =
      render_component(&MetricCard.metric_card/1,
        id: "metric-map-meta",
        label: "Latency",
        value: 12,
        meta: %{"range" => "30d", "hint" => "healthy", "href" => "/hidden", "p95_latency" => 1234}
      )

    assert html =~ "range: 30d"
    assert html =~ "healthy"
    assert html =~ "p95 latency: 1,234"
    refute html =~ "/hidden"
  end

  test "metric_card/1 falls back to empty display metadata for invalid meta" do
    html =
      render_component(&MetricCard.metric_card/1,
        id: "metric-invalid-meta",
        label: "Fallback",
        value: 99,
        meta: :invalid,
        range: "fallback range",
        hint: "fallback hint"
      )

    assert html =~ "range: fallback range"
    assert html =~ "fallback hint"
  end

  test "metric_card/1 handles missing primary_link assign when called directly" do
    assigns =
      %Phoenix.LiveView.Socket{}
      |> Phoenix.Component.assign(:id, "direct-card")
      |> Phoenix.Component.assign(:label, "Direct")
      |> Phoenix.Component.assign(:value, 5)
      |> Phoenix.Component.assign(:display, %{extra: %{ignored: "value"}})
      |> Phoenix.Component.assign(:range, "manual")
      |> Phoenix.Component.assign(:hint, "hint")
      |> Map.fetch!(:assigns)

    html =
      MetricCard.metric_card(assigns)
      |> rendered_to_string()

    assert html =~ ~s(id="direct-card")
    assert html =~ "Direct"
    assert html =~ "range: manual"
    assert html =~ "hint"
    refute html =~ "ignored: value"
  end

  test "metric_card/1 renders display metadata but not runtime metadata on the article" do
    html =
      render_component(&MetricCard.metric_card/1,
        id: "metric-runtime-separation-card",
        card: %ScalarPayload{
          id: "metric-runtime-separation",
          label: "API calls",
          value: 120,
          display: %DisplayMeta{range: "30d", hint: "scope: critical"},
          runtime: %RuntimeMeta{href: "/bo/hidden-runtime"}
        }
      )

    assert html =~ "range: 30d"
    assert html =~ "scope: critical"
    refute html =~ ~s(id="metric-runtime-separation-card" href=)
  end

  test "metric_card/1 auto-wraps with primary link from card.runtime.href" do
    html =
      render_component(&MetricCard.metric_card/1,
        id: "dashboard-metric-documents-ingested-card",
        card: %ScalarPayload{
          id: "dashboard-metric-documents-ingested",
          label: "Documents ingested",
          value: 128,
          display: %DisplayMeta{range: "30d"},
          runtime: %RuntimeMeta{href: "/bo/ingestion"}
        }
      )

    assert html =~ ~s(id="dashboard-metric-documents-ingested")
    assert html =~ ~s(href="/bo/ingestion")
    assert html =~ "id=\"dashboard-metric-documents-ingested-card\""
  end

  test "metric_card/1 explicit primary_link overrides card.runtime.href" do
    html =
      render_component(&MetricCard.metric_card/1,
        id: "metric-card",
        card: %ScalarPayload{
          id: "metric-id",
          label: "API calls",
          value: 10,
          runtime: %RuntimeMeta{href: "/bo/from-runtime"}
        },
        primary_link: %{destination: "/bo/explicit", id: "metric-id"}
      )

    assert html =~ ~s(href="/bo/explicit")
    refute html =~ "/bo/from-runtime"
  end

  test "metric_card/1 renders secondary_link with nav_link styling" do
    html =
      render_component(&MetricCard.metric_card/1,
        id: "metric-card",
        label: "Documents ingested",
        value: 42,
        secondary_link: %{
          id: "dashboard-knowledge-base-metrics-link",
          destination: "/bo/dashboard/knowledge-base-metrics",
          label: "View Knowledge base metrics"
        }
      )

    assert html =~ "id=\"dashboard-knowledge-base-metrics-link\""
    assert html =~ ~s(href="/bo/dashboard/knowledge-base-metrics")
    assert html =~ "View Knowledge base metrics"
    assert html =~ "zaq-link--accent"
    assert html =~ "hero-arrow-right"
  end

  test "metric_card/1 renders primary and secondary links together" do
    html =
      render_component(&MetricCard.metric_card/1,
        id: "dashboard-metric-documents-ingested-card",
        label: "Documents ingested",
        value: 128,
        primary_link: %{
          id: "dashboard-metric-documents-ingested",
          destination: "/bo/ingestion"
        },
        secondary_link: %{
          id: "dashboard-knowledge-base-metrics-link",
          destination: "/bo/dashboard/knowledge-base-metrics",
          label: "View Knowledge base metrics"
        }
      )

    assert html =~ "space-y-2"
    assert html =~ ~s(id="dashboard-metric-documents-ingested")
    assert html =~ "id=\"dashboard-metric-documents-ingested-card\""
    assert html =~ "id=\"dashboard-knowledge-base-metrics-link\""
  end
end
