defmodule Storybook.Dashboard.MetricOverview do
  use PhoenixStorybook.Story, :page
  use Phoenix.Component

  import ZaqWeb.Dashboard.MetricOverview

  alias Zaq.Engine.Telemetry.Contracts.{DisplayMeta, RuntimeMeta}
  alias Zaq.Engine.Telemetry.Contracts.Payloads.ScalarPayload

  def description,
    do: "BO Dashboard — KPI grid with `BOTelemetryComponents.metric_card` and sub-metric links."

  def render(assigns) do
    metrics = sample_metrics()
    assigns = assign(assigns, :metric_cards, metrics)

    ~H"""
    <div class="zaq-text-body" style="padding: var(--zaq-scale-32); max-width: 1200px;">
      <p
        class="zaq-text-caption"
        style="color: var(--zaq-text-color-body-tertiary); margin-bottom: var(--zaq-scale-24);"
      >
        Default — three KPI columns with deep links (matches `/bo/dashboard` structure).
      </p>
      <.metric_overview metric_cards={@metric_cards} />
    </div>
    """
  end

  defp sample_metrics do
    [
      %ScalarPayload{
        id: "dashboard-metric-documents-ingested",
        label: "Documents ingested",
        value: 128.0,
        unit: nil,
        trend: nil,
        display: %DisplayMeta{range: "30d", hint: "ingestion pipeline completions"},
        runtime: %RuntimeMeta{href: "/bo/ingestion"}
      },
      %ScalarPayload{
        id: "dashboard-metric-llm-api-calls",
        label: "LLM API calls",
        value: 4_200,
        unit: nil,
        trend: nil,
        display: %DisplayMeta{range: "30d", hint: "answering throughput"},
        runtime: %RuntimeMeta{href: "/bo/ai-diagnostics"}
      },
      %ScalarPayload{
        id: "dashboard-metric-qa-response-time",
        label: "Conversations average response time",
        value: 842.0,
        unit: "ms",
        trend: nil,
        display: %DisplayMeta{range: "30d", hint: "weighted mean latency"},
        runtime: %RuntimeMeta{href: "/bo/chat"}
      }
    ]
  end
end
