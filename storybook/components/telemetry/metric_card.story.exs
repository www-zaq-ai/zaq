defmodule Storybook.Components.Telemetry.MetricCard do
  use PhoenixStorybook.Story, :component

  def function, do: &ZaqWeb.Components.BOTelemetryComponents.metric_card/1
  def description, do: "KPI tile with value, unit, trend indicator, and optional hint tooltip."

  def variations do
    [
      %VariationGroup{
        id: :trends,
        description: "Trend variants",
        variations: [
          %Variation{
            id: :positive_trend,
            description: "Positive trend",
            attributes: %{
              id: "card-queries",
              label: "Queries today",
              value: 1_284,
              unit: "queries",
              trend: 0.12,
              range: "vs yesterday"
            }
          },
          %Variation{
            id: :negative_trend,
            description: "Negative trend",
            attributes: %{
              id: "card-errors",
              label: "Error rate",
              value: 3.4,
              unit: "%",
              trend: -0.08,
              range: "vs last week"
            }
          },
          %Variation{
            id: :no_trend,
            description: "No trend data",
            attributes: %{
              id: "card-agents",
              label: "Active agents",
              value: 7,
              unit: "agents"
            }
          },
          %Variation{
            id: :with_hint,
            description: "With hint tooltip",
            attributes: %{
              id: "card-confidence",
              label: "Avg confidence",
              value: 0.83,
              unit: "score",
              trend: 0.04,
              range: "vs last month",
              hint: "Average confidence score across all answered queries."
            }
          }
        ]
      }
    ]
  end
end
