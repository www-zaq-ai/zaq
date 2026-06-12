defmodule Storybook.Components.DesignSystem.StatusPill do
  use PhoenixStorybook.Story, :page
  use Phoenix.Component

  alias ZaqWeb.Components.DesignSystem.StatusPill, as: StatusPillMod

  def description, do: "Ingestion job status → pill CSS classes (`StatusPill.status_color/1`)."

  def render(assigns) do
    statuses = ~w(pending processing completed completed_with_errors failed unknown)

    assigns = assign(assigns, :statuses, statuses)

    ~H"""
    <div style="padding: var(--zaq-scale-32); display: flex; flex-direction: column; gap: var(--zaq-scale-16);">
      <p class="zaq-text-caption" style="color: var(--zaq-text-color-body-tertiary);">
        ZaqWeb.Components.DesignSystem.StatusPill.status_color/1
      </p>
      <div style="display: flex; flex-wrap: wrap; gap: var(--zaq-scale-12); align-items: center;">
        <span
          :for={s <- @statuses}
          class={["font-mono text-[0.65rem] px-2 py-0.5 rounded", StatusPillMod.status_color(s)]}
        >
          {s}
        </span>
      </div>
    </div>
    """
  end
end
