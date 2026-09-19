defmodule Storybook.Components.Cards.CardShell do
  use PhoenixStorybook.Story, :page
  use Phoenix.Component

  import ZaqWeb.Components.DesignSystem.CardShell, only: [card_shell: 1]

  def description do
    "Shared BO card shell — `.zaq-card-*` surface, optional primary navigation (hover), " <>
      "`:muted` static cards, footer ghost button, and secondary link below."
  end

  def render(assigns) do
    ~H"""
    <div
      class="zaq-text-body"
      style="display: flex; flex-direction: column; gap: var(--zaq-scale-32); padding: var(--zaq-scale-24); max-width: 48rem;"
    >
      <section>
        <p class="zaq-text-body-sm" style="color: var(--zaq-text-color-body-secondary); margin: 0;">
          Primary link
        </p>
        <.card_shell
          id="story-card-linked"
          as={:article}
          primary_link={%{destination: "/bo/channels/retrieval"}}
        >
          <p class="zaq-text-h3">Communication Channels</p>
          <p class="zaq-text-body-sm" style="color: var(--zaq-text-color-body-secondary);">
            Whole card navigates; hover uses `.zaq-card-hover`.
          </p>
        </.card_shell>
      </section>

      <section>
        <p class="zaq-text-body-sm" style="color: var(--zaq-text-color-body-secondary); margin: 0;">
          Muted (no link)
        </p>
        <.card_shell id="story-card-muted" as={:article} variant={:muted}>
          <p class="zaq-text-h3">AI Agents</p>
          <p class="zaq-text-body-sm" style="color: var(--zaq-text-color-body-secondary);">
            Coming soon — no hover affordance.
          </p>
        </.card_shell>
      </section>

      <section>
        <p class="zaq-text-body-sm" style="color: var(--zaq-text-color-body-secondary); margin: 0;">
          Footer ghost button (same destination as primary)
        </p>
        <.card_shell
          id="story-card-footer"
          as={:article}
          primary_link={%{destination: "/bo/channels/retrieval/mattermost"}}
          footer_link={
            %{
              id: "story-card-footer-configure",
              label: "Configure",
              destination: "/bo/channels/retrieval/mattermost",
              icon: "hero-arrow-right",
              icon_position: :right
            }
          }
        >
          <p class="zaq-text-h3">Mattermost</p>
          <p class="zaq-text-body-sm" style="color: var(--zaq-text-color-body-secondary);">
            Header and body inside the primary link; footer button navigates separately.
          </p>
        </.card_shell>
      </section>

      <section>
        <p class="zaq-text-body-sm" style="color: var(--zaq-text-color-body-secondary); margin: 0;">
          Primary + secondary link
        </p>
        <.card_shell
          id="story-card-secondary"
          as={:article}
          primary_link={%{id: "story-metric-link", destination: "/bo/ingestion"}}
          secondary_link={
            %{
              id: "story-metric-secondary",
              destination: "/bo/dashboard/knowledge-base-metrics",
              label: "View Knowledge base metrics"
            }
          }
        >
          <p
            class="zaq-text-caption uppercase tracking-[0.18em]"
            style="color: var(--zaq-text-color-body-secondary);"
          >
            Documents ingested
          </p>
          <p class="zaq-text-h1">128</p>
        </.card_shell>
      </section>
    </div>
    """
  end
end
