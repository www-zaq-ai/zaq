defmodule Storybook.Components.DesignSystem.StatusDot do
  use PhoenixStorybook.Story, :page
  use Phoenix.Component

  import ZaqWeb.Components.DesignSystem.StatusDot

  def description do
    "Inline status dot for BO surfaces. `:active` (green), `:inactive` (red), " <>
      "and optional `count` for notification counters (caps at `+99`). " <>
      "Styles: `.zaq-status-dot*` in `styles.css`."
  end

  def render(assigns) do
    ~H"""
    <div class="zaq-layout-stack" style="padding: var(--zaq-scale-32);">
      <p class="zaq-text-caption" style="color: var(--zaq-text-color-body-tertiary);">
        &lt;ZaqWeb.Components.DesignSystem.StatusDot.status_dot status={:active} /&gt;
      </p>

      <div class="zaq-layout-inline" style="flex-wrap: wrap;">
        <.demo label=":active">
          <.status_dot status={:active} />
        </.demo>
        <.demo label=":inactive">
          <.status_dot status={:inactive} />
        </.demo>
        <.demo label="count={3}">
          <.status_dot status={:active} count={3} />
        </.demo>
        <.demo label="count={99}">
          <.status_dot status={:inactive} count={99} />
        </.demo>
        <.demo label="count={150} → +99">
          <.status_dot status={:active} count={150} />
        </.demo>
      </div>
    </div>
    """
  end

  defp demo(assigns) do
    ~H"""
    <div class="zaq-layout-stack-tight" style="align-items: flex-start;">
      <span class="zaq-text-caption" style="color: var(--zaq-text-color-body-tertiary);">
        {@label}
      </span>
      {render_slot(@inner_block)}
    </div>
    """
  end
end
