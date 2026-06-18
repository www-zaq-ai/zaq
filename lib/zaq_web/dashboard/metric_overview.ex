defmodule ZaqWeb.Dashboard.MetricOverview do
  @moduledoc """
  BO main dashboard — KPI metric cards grid and deep links to metric sub-pages.
  """

  use Phoenix.Component

  import ZaqWeb.Components.BOTelemetryComponents, only: [metric_card: 1]

  attr :metric_cards, :list, required: true

  def metric_overview(assigns) do
    ~H"""
    <div class="mb-8 grid grid-cols-1 gap-4 md:grid-cols-2 xl:grid-cols-3">
      <div :for={metric <- @metric_cards} class="space-y-2">
        <.link
          id={metric.id}
          navigate={metric.runtime.href || "/bo/dashboard"}
          class="group block"
        >
          <.metric_card id={metric.id <> "-card"} card={metric} />
        </.link>

        <.link
          :if={metric.id == "dashboard-metric-documents-ingested"}
          id="dashboard-knowledge-base-metrics-link"
          navigate="/bo/dashboard/knowledge-base-metrics"
          class="inline-flex items-center gap-2 rounded-lg border border-[#03b6d4]/25 bg-white px-3 py-1.5 font-mono text-[0.68rem] font-semibold text-[#03b6d4] transition-colors hover:bg-[#03b6d4]/10"
        >
          View Knowledge base metrics <span class="text-[0.8rem]">-&gt;</span>
        </.link>

        <.link
          :if={metric.id == "dashboard-metric-llm-api-calls"}
          id="dashboard-llm-performance-link"
          navigate="/bo/dashboard/llm-performance"
          class="inline-flex items-center gap-2 rounded-lg border border-[#03b6d4]/25 bg-white px-3 py-1.5 font-mono text-[0.68rem] font-semibold text-[#03b6d4] transition-colors hover:bg-[#03b6d4]/10"
        >
          View LLM performance <span class="text-[0.8rem]">-&gt;</span>
        </.link>

        <.link
          :if={metric.id == "dashboard-metric-qa-response-time"}
          id="dashboard-conversations-metrics-link"
          navigate="/bo/dashboard/conversations-metrics"
          class="inline-flex items-center gap-2 rounded-lg border border-[#03b6d4]/25 bg-white px-3 py-1.5 font-mono text-[0.68rem] font-semibold text-[#03b6d4] transition-colors hover:bg-[#03b6d4]/10"
        >
          View Conversations metrics <span class="text-[0.8rem]">-&gt;</span>
        </.link>
      </div>
    </div>
    """
  end
end
