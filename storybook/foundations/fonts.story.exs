defmodule Storybook.Foundations.Fonts do
  use PhoenixStorybook.Story, :page

  def description,
    do: "ZAQ font families and weights — foundation tokens for heading, body, and code."

  def render(assigns) do
    ~H"""
    <div style="font-family: var(--zaq-font-family-body, sans-serif); padding: 2rem; display: flex; flex-direction: column; gap: 3rem; max-width: 760px;">
      <div style="background: rgba(255, 200, 60, 0.1); border: 1px solid rgba(255, 180, 0, 0.3); border-radius: 8px; padding: 0.75rem 1rem; font-size: 0.75rem; line-height: 1.5; color: inherit;">
        <strong style="font-weight: 600;">Foundation tokens are source values only.</strong>
        They exist to define semantic tokens — never reference them directly in components or pages.
        Use <strong style="font-weight: 600;">semantic tokens</strong>
        in all UI code.
      </div>
      
    <!-- Font Families -->
      <section>
        <h2 style="font-size: 0.7rem; font-weight: 600; letter-spacing: 0.1em; text-transform: uppercase; opacity: 0.45; margin-bottom: 1.5rem;">
          Font Families
        </h2>
        <div style="display: flex; flex-direction: column; gap: 1.5rem;">
          <.font_row
            sample="Heading — Hanken Grotesk"
            style="font-family: var(--zaq-font-family-heading); font-size: 1.5rem; font-weight: 600;"
            var="--zaq-font-family-heading"
            detail="Hanken Grotesk · headings"
          />
          <.font_row
            sample="Body — Inter"
            style="font-family: var(--zaq-font-family-body); font-size: 1rem; font-weight: 400;"
            var="--zaq-font-family-body"
            detail="Inter · body text"
          />
          <.font_row
            sample="Code — JetBrains Mono"
            style="font-family: var(--zaq-font-family-code); font-size: 1rem; font-weight: 400;"
            var="--zaq-font-family-code"
            detail="JetBrains Mono · code &amp; data"
          />
        </div>
      </section>
      
    <!-- Font Weights -->
      <section>
        <h2 style="font-size: 0.7rem; font-weight: 600; letter-spacing: 0.1em; text-transform: uppercase; opacity: 0.45; margin-bottom: 1.5rem;">
          Font Weights
        </h2>
        <div style="display: flex; flex-direction: column; gap: 1.5rem;">
          <.font_row
            sample="Regular — The quick brown fox"
            style="font-family: var(--zaq-font-family-body); font-size: 1rem; font-weight: var(--zaq-font-weight-regular);"
            var="--zaq-font-weight-regular"
            detail="400 · body, caption, code"
          />
          <.font_row
            sample="SemiBold — The quick brown fox"
            style="font-family: var(--zaq-font-family-heading); font-size: 1rem; font-weight: var(--zaq-font-weight-semibold);"
            var="--zaq-font-weight-semibold"
            detail="600 · headings h2–h5"
          />
        </div>
      </section>
      
    <!-- Line Heights -->
      <section>
        <h2 style="font-size: 0.7rem; font-weight: 600; letter-spacing: 0.1em; text-transform: uppercase; opacity: 0.45; margin-bottom: 1.5rem;">
          Line Heights
        </h2>
        <div style="display: flex; flex-direction: column; gap: 1.5rem;">
          <.font_row
            sample="Tight — headings h2–h5"
            style="font-family: var(--zaq-font-family-heading); font-size: 1rem; font-weight: 600; line-height: var(--zaq-line-height-tight);"
            var="--zaq-line-height-tight"
            detail="1.2 · headings"
          />
          <.font_row
            sample="Normal — page titles"
            style="font-family: var(--zaq-font-family-heading); font-size: 1rem; font-weight: 600; line-height: var(--zaq-line-height-normal);"
            var="--zaq-line-height-normal"
            detail="1.4 · h1"
          />
          <.font_row
            sample="Relaxed — body copy and captions"
            style="font-family: var(--zaq-font-family-body); font-size: 1rem; font-weight: 400; line-height: var(--zaq-line-height-relaxed);"
            var="--zaq-line-height-relaxed"
            detail="1.6 · body, caption, code"
          />
        </div>
      </section>
      
    <!-- Letter Spacing -->
      <section>
        <h2 style="font-size: 0.7rem; font-weight: 600; letter-spacing: 0.1em; text-transform: uppercase; opacity: 0.45; margin-bottom: 1.5rem;">
          Letter Spacing
        </h2>
        <div style="display: flex; flex-direction: column; gap: 1.5rem;">
          <.font_row
            sample="Default — no extra spacing"
            style="font-family: var(--zaq-font-family-body); font-size: 1rem; letter-spacing: var(--zaq-letter-spacing-default);"
            var="--zaq-letter-spacing-default"
            detail="0 · headings, body"
          />
          <.font_row
            sample="RELAXED — CAPTION TEXT, LABELS"
            style="font-family: var(--zaq-font-family-body); font-size: 0.75rem; font-weight: 600; text-transform: uppercase; letter-spacing: var(--zaq-letter-spacing-relaxed);"
            var="--zaq-letter-spacing-relaxed"
            detail="0.1em · caption, section labels"
          />
        </div>
      </section>
    </div>
    """
  end

  defp font_row(assigns) do
    ~H"""
    <div style="display: flex; flex-direction: column; gap: 0.25rem; padding-bottom: 1.25rem; border-bottom: 1px solid rgba(0,0,0,0.05);">
      <span style={@style}>
        {@sample}
      </span>
      <span style="font-family: ui-monospace, monospace; font-size: 0.65rem; opacity: 0.4;">
        {@var} · {@detail}
      </span>
    </div>
    """
  end
end
