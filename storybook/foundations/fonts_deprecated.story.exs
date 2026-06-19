defmodule Storybook.Foundations.FontsDeprecated do
  use PhoenixStorybook.Story, :page

  def description,
    do: "Deprecated font families — superseded by --font-family-* foundation tokens."

  def render(assigns) do
    ~H"""
    <div style="font-family: var(--zaq-font-primary, sans-serif); padding: 2rem; display: flex; flex-direction: column; gap: 3rem; max-width: 760px;">
      <div style="background: rgba(234, 0, 62, 0.06); border: 1px solid rgba(234, 0, 62, 0.25); border-radius: 8px; padding: 0.75rem 1rem; font-size: 0.75rem; line-height: 1.5; color: inherit;">
        <strong style="font-weight: 600;">⚠ Deprecated.</strong>
        These font families are no longer the source of truth.
        Use <code style="font-family: ui-monospace, monospace; font-size: 0.8em;">--font-family-heading</code>, <code style="font-family: ui-monospace, monospace; font-size: 0.8em;">--font-family-body</code>, and
        <code style="font-family: ui-monospace, monospace; font-size: 0.8em;">
          --font-family-code
        </code>
        defined in <strong style="font-weight: 600;">Foundation / Fonts</strong>
        instead.
      </div>
      
    <!-- Font families -->
      <section>
        <h2 style="font-size: 0.7rem; font-weight: 600; letter-spacing: 0.1em; text-transform: uppercase; opacity: 0.45; margin-bottom: 1.5rem;">
          Font Families
        </h2>
        <div style="display: flex; flex-direction: column; gap: 1.25rem;">
          <div style="display: flex; flex-direction: column; gap: 0.25rem;">
            <span style="font-family: var(--zaq-font-primary); font-size: 1.5rem; font-weight: 400;">
              ZAQ Sans — Primary UI
            </span>
            <span style="font-family: ui-monospace, monospace; font-size: 0.65rem; opacity: 0.4;">
              --zaq-font-primary · Roboto Variable
            </span>
          </div>
          <div style="display: flex; flex-direction: column; gap: 0.25rem;">
            <span style="font-family: var(--zaq-font-ui, sans-serif); font-size: 1.5rem; font-weight: 400;">
              Outfit — UI Accent
            </span>
            <span style="font-family: ui-monospace, monospace; font-size: 0.65rem; opacity: 0.4;">
              --zaq-font-ui · Outfit
            </span>
          </div>
          <div style="display: flex; flex-direction: column; gap: 0.25rem;">
            <span style="font-family: ui-monospace, monospace; font-size: 1.25rem;">
              Monospace — Code &amp; data
            </span>
            <span style="font-family: ui-monospace, monospace; font-size: 0.65rem; opacity: 0.4;">
              ui-monospace
            </span>
          </div>
        </div>
      </section>
    </div>
    """
  end
end
