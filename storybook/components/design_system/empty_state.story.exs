defmodule Storybook.Components.DesignSystem.EmptyState do
  use PhoenixStorybook.Story, :page
  use Phoenix.Component

  import ZaqWeb.Components.DesignSystem.EmptyState

  def description, do: "Centered empty-list message for BO master panels."

  def render(assigns) do
    ~H"""
    <div style="padding: var(--zaq-scale-32); max-width: 28rem; display: flex; flex-direction: column; gap: 2rem;">
      <.demo label="Title only">
        <.empty_state title="No results." />
      </.demo>
      <.demo label="People tab (from /bo/people)">
        <.empty_state title="No people yet." hint={"Click \"New Person\" to add one."} />
      </.demo>
      <.demo label="Teams tab (from /bo/people)">
        <.empty_state title="No teams yet." hint={"Click \"New Team\" to add one."} />
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
      <div style="border: 1px solid rgba(0,0,0,0.08); border-radius: 0.75rem;">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end
end
