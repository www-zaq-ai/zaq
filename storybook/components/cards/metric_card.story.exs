defmodule Storybook.Components.Cards.MetricCard do
  use PhoenixStorybook.Story, :page

  def description, do: "KPI tile with value, unit, trend indicator, and optional hint tooltip."

  def render(assigns) do
    ~H"""
    <div style="display: flex; flex-wrap: wrap; gap: 1rem; padding: 1.5rem;">
      <ZaqWeb.Components.BOTelemetryComponents.metric_card
        id="card-queries"
        label="Queries today"
        value={1_284}
        unit="queries"
        trend={0.12}
        range="vs yesterday"
      />
      <ZaqWeb.Components.BOTelemetryComponents.metric_card
        id="card-errors"
        label="Error rate"
        value={3.4}
        unit="%"
        trend={-0.08}
        range="vs last week"
      />
      <ZaqWeb.Components.BOTelemetryComponents.metric_card
        id="card-agents"
        label="Active agents"
        value={7}
        unit="agents"
      />
      <ZaqWeb.Components.BOTelemetryComponents.metric_card
        id="card-confidence"
        label="Avg confidence"
        value={0.83}
        unit="score"
        trend={0.04}
        range="vs last month"
        hint="Average confidence score across all answered queries."
      />
    </div>
    """
  end
end
