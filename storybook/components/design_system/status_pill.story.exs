defmodule Storybook.Components.DesignSystem.StatusPill do
  use PhoenixStorybook.Story, :page
  use Phoenix.Component

  alias ZaqWeb.Components.DesignSystem.StatusPill, as: StatusPillMod

  def description,
    do:
      "Ingestion job status pills (`StatusPill.status_pill_classes/1` + `.zaq-pill` in `styles.css`)."

  def render(assigns) do
    statuses =
      ~w(pending processing completed completed_with_errors failed cancelled stale ingested unknown)

    assigns = assign(assigns, :statuses, statuses)

    ~H"""
    <div style="padding: var(--zaq-scale-32); display: flex; flex-direction: column; gap: var(--zaq-scale-16);">
      <p class="zaq-text-caption" style="color: var(--zaq-text-color-body-tertiary);">
        ZaqWeb.Components.DesignSystem.StatusPill.status_pill_classes/1
      </p>
      <div style="display: flex; flex-wrap: wrap; gap: var(--zaq-scale-12); align-items: center;">
        <span :for={s <- @statuses} class={StatusPillMod.status_pill_classes(s)}>
          {s}
        </span>
        <span class={StatusPillMod.status_pill_classes("processing") ++ ["zaq-pill--pulse"]}>
          processing (pulse)
        </span>
      </div>
    </div>
    """
  end
end
