defmodule Storybook.Components.DesignSystem.StatusPill do
  use PhoenixStorybook.Story, :page
  use Phoenix.Component

  alias ZaqWeb.Components.DesignSystem.StatusPill, as: StatusPillMod

  def description,
    do:
      "Status pills (`StatusPill.status_pill_classes/1` + `.zaq-pill` in `styles.css`) for ingestion jobs, workflow lifecycle, and run/step statuses."

  attr :label, :string, required: true
  attr :statuses, :list, required: true

  defp status_group(assigns) do
    ~H"""
    <div style="display: flex; flex-direction: column; gap: var(--zaq-scale-8);">
      <p class="zaq-text-caption" style="color: var(--zaq-text-color-body-tertiary);">{@label}</p>
      <div style="display: flex; flex-wrap: wrap; gap: var(--zaq-scale-12); align-items: center;">
        <span :for={s <- @statuses} class={StatusPillMod.status_pill_classes(s)}>
          {s}
        </span>
      </div>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div style="padding: var(--zaq-scale-32); display: flex; flex-direction: column; gap: var(--zaq-scale-24);">
      <p class="zaq-text-caption" style="color: var(--zaq-text-color-body-tertiary);">
        ZaqWeb.Components.DesignSystem.StatusPill.status_pill_classes/1
      </p>
      <.status_group
        label="Ingestion jobs"
        statuses={
          ~w(pending processing completed completed_with_errors failed cancelled stale ingested unknown)
        }
      />
      <.status_group label="Workflow lifecycle" statuses={~w(draft active archived)} />
      <.status_group
        label="Workflow runs and step runs"
        statuses={
          ~w(running waiting paused interrupted incomplete completed failed failed_fatal skipped cancelled)
        }
      />
      <div style="display: flex; flex-direction: column; gap: var(--zaq-scale-8);">
        <p class="zaq-text-caption" style="color: var(--zaq-text-color-body-tertiary);">Modifiers</p>
        <div style="display: flex; flex-wrap: wrap; gap: var(--zaq-scale-12); align-items: center;">
          <span class={StatusPillMod.status_pill_classes("processing") ++ ["zaq-pill--pulse"]}>
            processing (pulse)
          </span>
        </div>
      </div>
    </div>
    """
  end
end
