defmodule Storybook.Components.DesignSystem.SimplePagination do
  use PhoenixStorybook.Story, :page
  use Phoenix.Component

  import ZaqWeb.Components.DesignSystem.SimplePagination

  def description, do: "Range label with Prev/Next for BO paginated list panels."

  def render(assigns) do
    ~H"""
    <div style="padding: var(--zaq-scale-32); max-width: 28rem; display: flex; flex-direction: column; gap: 2rem;">
      <.demo label="First page (Next only)">
        <.simple_pagination page={1} per_page={20} total_count={45} />
      </.demo>
      <.demo label="Middle page (Prev + Next)">
        <.simple_pagination page={2} per_page={20} total_count={45} />
      </.demo>
      <.demo label="Last page (Prev only)">
        <.simple_pagination page={3} per_page={20} total_count={45} />
      </.demo>
      <.demo label="Single page (range only)">
        <.simple_pagination page={1} per_page={20} total_count={5} />
      </.demo>
    </div>
    """
  end

  defp demo(assigns) do
    ~H"""
    <div style="display: flex; flex-direction: column; gap: 0.5rem;">
      <span style="font-size: 0.65rem; font-family: ui-monospace, monospace; opacity: 0.4;">
        {@label}
      </span>
      <div style="border: 1px solid rgba(0,0,0,0.08); border-radius: 0.75rem; overflow: hidden;">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end
end
