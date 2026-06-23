defmodule Storybook.Components.Cards.MetricCard do
  use PhoenixStorybook.Story, :page
  use Phoenix.Component

  import ZaqWeb.Components.DesignSystem.MetricCard, only: [metric_card: 1]

  alias Zaq.Engine.Telemetry.Contracts.{DisplayMeta, RuntimeMeta}
  alias Zaq.Engine.Telemetry.Contracts.Payloads.ScalarPayload

  def description do
    "KPI tile (`DesignSystem.MetricCard`) with optional **`primary_link`** (card wrapper) and " <>
      "**`secondary_link`** (`DesignSystem.Link` below the card). " <>
      "**Navigation sections** (primary only, auto primary, both links) are distinct API modes. " <>
      "**No links** shows one mode — display-only cards — with several sample data shapes side by side."
  end

  def render(assigns) do
    ~H"""
    <div
      class="zaq-text-body"
      style="display: flex; flex-direction: column; gap: var(--zaq-scale-32); padding: var(--zaq-scale-24);"
    >
      <section>
        <p class="zaq-text-body-sm" style="color: var(--zaq-text-color-body-secondary); margin: 0;">
          No links — display-only cards
        </p>
        <p
          class="zaq-text-caption"
          style="color: var(--zaq-text-color-body-tertiary); margin: var(--zaq-scale-8) 0 var(--zaq-scale-16); max-width: 42rem;"
        >
          Same API mode: omit `primary_link` and `secondary_link`. Each example below is a single
          card instance with different optional fields (unit, trend, range, hint) — not a composite
          “default group”. On live pages you typically render one card per slot.
        </p>
        <div style="display: flex; flex-wrap: wrap; gap: var(--zaq-scale-24); align-items: flex-start;">
          <.example label="Full — unit, positive trend, range">
            <.metric_card
              id="card-queries"
              label="Queries today"
              value={1_284}
              unit="queries"
              trend={0.12}
              range="vs yesterday"
            />
          </.example>
          <.example label="Negative trend">
            <.metric_card
              id="card-errors"
              label="Error rate"
              value={3.4}
              unit="%"
              trend={-0.08}
              range="vs last week"
            />
          </.example>
          <.example label="Minimal — value and unit only">
            <.metric_card id="card-agents" label="Active agents" value={7} unit="agents" />
          </.example>
          <.example label="With hint in metadata footer">
            <.metric_card
              id="card-confidence"
              label="Avg confidence"
              value={0.83}
              unit="score"
              trend={0.04}
              range="vs last month"
              hint="Average confidence score across all answered queries."
            />
          </.example>
        </div>
      </section>

      <section>
        <p class="zaq-text-body-sm" style="color: var(--zaq-text-color-body-secondary); margin: 0;">
          Primary link only — explicit `primary_link` map
        </p>
        <p
          class="zaq-text-caption"
          style="color: var(--zaq-text-color-body-tertiary); margin: var(--zaq-scale-8) 0 var(--zaq-scale-16); max-width: 42rem;"
        >
          Card is wrapped in a block link. Pass a `primary_link` map with `destination` and optional `id`.
        </p>
        <.metric_card
          id="card-primary-only"
          label="Documents ingested"
          value={128}
          range="30d"
          primary_link={%{id: "story-metric-primary", destination: "/bo/ingestion"}}
        />
      </section>

      <section>
        <p class="zaq-text-body-sm" style="color: var(--zaq-text-color-body-secondary); margin: 0;">
          Primary link only — auto-filled from `card.runtime.href`
        </p>
        <p
          class="zaq-text-caption"
          style="color: var(--zaq-text-color-body-tertiary); margin: var(--zaq-scale-8) 0 var(--zaq-scale-16); max-width: 42rem;"
        >
          When `primary_link` is omitted and `card` is a `%ScalarPayload{}` with `runtime.href`, the
          component wraps the card automatically (link `id` uses `card.id`).
        </p>
        <.metric_card
          id="story-metric-auto-primary-card"
          card={
            %ScalarPayload{
              id: "story-metric-auto-primary",
              label: "LLM API calls",
              value: 4_200,
              display: %DisplayMeta{range: "30d", hint: "answering throughput"},
              runtime: %RuntimeMeta{href: "/bo/ai-diagnostics"}
            }
          }
        />
      </section>

      <section>
        <p class="zaq-text-body-sm" style="color: var(--zaq-text-color-body-secondary); margin: 0;">
          Primary + secondary — dashboard KPI pattern
        </p>
        <p
          class="zaq-text-caption"
          style="color: var(--zaq-text-color-body-tertiary); margin: var(--zaq-scale-8) 0 var(--zaq-scale-16); max-width: 42rem;"
        >
          Clickable card plus a `DesignSystem.Link` CTA below. Destinations are independent;
          `secondary_link` always requires an explicit `label` and `destination`.
        </p>
        <.metric_card
          id="story-metric-both-links-card"
          label="Documents ingested"
          value={128}
          range="30d"
          primary_link={%{id: "story-metric-both", destination: "/bo/ingestion"}}
          secondary_link={
            %{
              id: "story-metric-secondary",
              destination: "/bo/dashboard/knowledge-base-metrics",
              label: "View Knowledge base metrics"
            }
          }
        />
      </section>
    </div>
    """
  end

  attr :label, :string, required: true
  slot :inner_block, required: true

  defp example(assigns) do
    ~H"""
    <div style="display: flex; flex-direction: column; gap: var(--zaq-scale-8); max-width: 16rem;">
      <span
        class="zaq-text-caption"
        style="color: var(--zaq-text-color-body-tertiary); font-family: ui-monospace, monospace;"
      >
        {@label}
      </span>
      {render_slot(@inner_block)}
    </div>
    """
  end
end
