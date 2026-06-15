defmodule Storybook.Playground.ButtonPlayground do
  use PhoenixStorybook.Story, :page

  def description,
    do:
      "Playground for .zaq-btn-primary, .zaq-btn-secondary, .zaq-btn-ghost, and .zaq-btn-tertiary — all states, both themes."

  def render(assigns) do
    ~H"""
    <div style="font-family: var(--zaq-font-family-body, sans-serif); padding: 2rem; display: flex; flex-direction: column; gap: 3rem;">
      <section>
        <.section_label>Primary</.section_label>
        <.row>
          <button class="zaq-btn zaq-btn-primary zaq-btn-text_label-default">Resting</button>
          <button class="zaq-btn zaq-btn-primary zaq-btn-text_label-default" disabled>
            Disabled
          </button>
        </.row>
        <.hint>Hover state is :hover CSS pseudo-class — visible in the browser on mouse-over.</.hint>
      </section>

      <section>
        <.section_label>Secondary</.section_label>
        <.row>
          <button class="zaq-btn zaq-btn-secondary zaq-btn-text_label-default">Resting</button>
          <button class="zaq-btn zaq-btn-secondary zaq-btn-text_label-default" disabled>
            Disabled
          </button>
        </.row>
        <.hint>Hover state is :hover CSS pseudo-class — visible in the browser on mouse-over.</.hint>
      </section>

      <section>
        <.section_label>Ghost</.section_label>
        <.row>
          <button class="zaq-btn zaq-btn-ghost zaq-btn-text_label-default">Resting</button>
          <button class="zaq-btn zaq-btn-ghost zaq-btn-text_label-default" disabled>Disabled</button>
        </.row>
        <.hint>Hover state is :hover CSS pseudo-class — visible in the browser on mouse-over.</.hint>
      </section>

      <section>
        <.section_label>Tertiary</.section_label>
        <.row>
          <button type="button" class="zaq-btn zaq-btn-tertiary zaq-btn-text_label-default">
            Resting
          </button>
          <button
            type="button"
            class="zaq-btn zaq-btn-tertiary zaq-btn-tertiary--active zaq-btn-text_label-default"
          >
            Active
          </button>
          <button
            type="button"
            class="zaq-btn zaq-btn-tertiary zaq-btn-danger zaq-btn-text_label-default"
          >
            Delete
          </button>
        </.row>
        <.hint>
          `.zaq-btn` supplies layout; `.zaq-btn-tertiary*` neutral chrome; `.zaq-btn-danger` destructive; `.zaq-btn-text_label-default` for button label type (per `text-styles.css`).
        </.hint>
      </section>

      <section>
        <.section_label>With Icon</.section_label>
        <.row>
          <button class="zaq-btn zaq-btn-primary zaq-btn-text_label-default">
            <ZaqWeb.CoreComponents.icon name="hero-x-mark" class="w-4 h-4" /> Dismiss
          </button>
          <button class="zaq-btn zaq-btn-primary zaq-btn-text_label-default" disabled>
            <ZaqWeb.CoreComponents.icon name="hero-x-mark" class="w-4 h-4" /> Dismiss
          </button>
          <button class="zaq-btn zaq-btn-secondary zaq-btn-text_label-default">
            <ZaqWeb.CoreComponents.icon name="hero-trash" class="w-4 h-4" /> Delete
          </button>
          <button class="zaq-btn zaq-btn-secondary zaq-btn-text_label-default" disabled>
            <ZaqWeb.CoreComponents.icon name="hero-trash" class="w-4 h-4" /> Delete
          </button>
          <button class="zaq-btn zaq-btn-ghost zaq-btn-text_label-default">
            <ZaqWeb.CoreComponents.icon name="hero-x-mark" class="w-4 h-4" /> Dismiss
          </button>
          <button class="zaq-btn zaq-btn-ghost zaq-btn-text_label-default" disabled>
            <ZaqWeb.CoreComponents.icon name="hero-x-mark" class="w-4 h-4" /> Dismiss
          </button>
        </.row>
        <.hint>Icon color inherits from button text color via currentColor.</.hint>
      </section>

      <section>
        <.section_label>Icon Only</.section_label>
        <.row>
          <button class="zaq-btn zaq-btn-primary zaq-btn-square" aria-label="Dismiss" title="Dismiss">
            <ZaqWeb.CoreComponents.icon name="hero-x-mark" class="w-6 h-6" />
          </button>
          <button
            class="zaq-btn zaq-btn-primary zaq-btn-square"
            aria-label="Dismiss"
            title="Dismiss"
            disabled
          >
            <ZaqWeb.CoreComponents.icon name="hero-x-mark" class="w-6 h-6" />
          </button>
          <button class="zaq-btn zaq-btn-secondary zaq-btn-square" aria-label="Delete" title="Delete">
            <ZaqWeb.CoreComponents.icon name="hero-trash" class="w-6 h-6" />
          </button>
          <button
            class="zaq-btn zaq-btn-secondary zaq-btn-square"
            aria-label="Delete"
            title="Delete"
            disabled
          >
            <ZaqWeb.CoreComponents.icon name="hero-trash" class="w-6 h-6" />
          </button>
          <button class="zaq-btn zaq-btn-ghost zaq-btn-square" aria-label="Dismiss" title="Dismiss">
            <ZaqWeb.CoreComponents.icon name="hero-x-mark" class="w-6 h-6" />
          </button>
          <button
            class="zaq-btn zaq-btn-ghost zaq-btn-square"
            aria-label="Dismiss"
            title="Dismiss"
            disabled
          >
            <ZaqWeb.CoreComponents.icon name="hero-x-mark" class="w-6 h-6" />
          </button>
        </.row>
        <.hint>aria-label obligatoire — aucun texte visible ne décrit l'action.</.hint>
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
