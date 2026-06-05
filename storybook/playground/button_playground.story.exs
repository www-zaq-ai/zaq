defmodule Storybook.Playground.ButtonPlayground do
  use PhoenixStorybook.Story, :page

  def description, do: "Playground for .zaq-btn-primary and .zaq-btn-secondary — all states, both themes."

  def render(assigns) do
    ~H"""
    <div style="font-family: var(--zaq-font-family-body, sans-serif); padding: 2rem; display: flex; flex-direction: column; gap: 3rem;">

      <section>
        <.section_label>Primary</.section_label>
        <.row>
          <button class="zaq-btn zaq-btn-primary zaq-btn-text_label-default">Resting</button>
          <button class="zaq-btn zaq-btn-primary zaq-btn-text_label-default" disabled>Disabled</button>
        </.row>
        <.hint>Hover state is :hover CSS pseudo-class — visible in the browser on mouse-over.</.hint>
      </section>

      <section>
        <.section_label>Secondary</.section_label>
        <.row>
          <button class="zaq-btn zaq-btn-secondary zaq-btn-text_label-default">Resting</button>
          <button class="zaq-btn zaq-btn-secondary zaq-btn-text_label-default" disabled>Disabled</button>
        </.row>
        <.hint>Hover state is :hover CSS pseudo-class — visible in the browser on mouse-over.</.hint>
      </section>

      <section>
        <.section_label>Side by side</.section_label>
        <.row>
          <button class="zaq-btn zaq-btn-primary zaq-btn-text_label-default">Primary</button>
          <button class="zaq-btn zaq-btn-secondary zaq-btn-text_label-default">Secondary</button>
        </.row>
      </section>

      <section>
        <.section_label>On dark background</.section_label>
        <div style="background: var(--zaq-surface-color-dark); padding: 1.5rem; border-radius: 8px; display: flex; gap: 1rem; align-items: center; flex-wrap: wrap;">
          <button class="zaq-btn zaq-btn-primary zaq-btn-text_label-default">Primary</button>
          <button class="zaq-btn zaq-btn-secondary zaq-btn-text_label-default">Secondary</button>
          <button class="zaq-btn zaq-btn-primary zaq-btn-text_label-default" disabled>Disabled</button>
          <button class="zaq-btn zaq-btn-secondary zaq-btn-text_label-default" disabled>Disabled</button>
        </div>
      </section>

    </div>
    """
  end

  defp section_label(assigns) do
    ~H"""
    <h2 style="font-size: 0.7rem; font-weight: 600; letter-spacing: 0.1em; text-transform: uppercase; opacity: 0.45; margin-bottom: 1rem;">
      {render_slot(@inner_block)}
    </h2>
    """
  end

  defp row(assigns) do
    ~H"""
    <div style="display: flex; gap: 1rem; align-items: center; flex-wrap: wrap;">
      {render_slot(@inner_block)}
    </div>
    """
  end

  defp hint(assigns) do
    ~H"""
    <p style="font-size: 0.65rem; opacity: 0.4; margin-top: 0.5rem; font-family: ui-monospace, monospace;">
      {render_slot(@inner_block)}
    </p>
    """
  end
end
