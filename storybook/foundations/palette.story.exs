defmodule Storybook.Foundations.Palette do
  use PhoenixStorybook.Story, :page

  def description,
    do:
      "Raw color palette tokens defined in foundations.css — the source values all semantic tokens map to."

  def render(assigns) do
    ~H"""
    <div style="font-family: var(--zaq-font-primary, sans-serif); padding: 2rem; display: flex; flex-direction: column; gap: 3rem;">
      <div style="background: rgba(255, 200, 60, 0.1); border: 1px solid rgba(255, 180, 0, 0.3); border-radius: 8px; padding: 0.75rem 1rem; font-size: 0.75rem; line-height: 1.5; color: inherit;">
        <strong style="font-weight: 600;">Foundation tokens are source values only.</strong>
        They exist to define semantic tokens — never reference them directly in components or pages.
        Use <strong style="font-weight: 600;">semantic tokens</strong>
        (e.g. <code style="font-family: ui-monospace, monospace; font-size: 0.8em;">--zaq-color-surface-base</code>, <code style="font-family: ui-monospace, monospace; font-size: 0.8em;">--zaq-color-border-default</code>) in all UI code.
      </div>

      <section>
        <h2 style="font-size: 0.7rem; font-weight: 600; letter-spacing: 0.1em; text-transform: uppercase; opacity: 0.45; margin-bottom: 1rem;">
          Blue
        </h2>
        <div style="display: grid; grid-template-columns: repeat(4, 1fr); gap: 0.75rem;">
          <.swatch name="blue-400" var="--zaq-color-blue-400" />
          <.swatch name="blue-300" var="--zaq-color-blue-300" />
          <.swatch name="blue-200" var="--zaq-color-blue-200" />
          <.swatch name="blue-100" var="--zaq-color-blue-100" />
        </div>
      </section>

      <section>
        <h2 style="font-size: 0.7rem; font-weight: 600; letter-spacing: 0.1em; text-transform: uppercase; opacity: 0.45; margin-bottom: 1rem;">
          Black / Ink
        </h2>
        <div style="display: grid; grid-template-columns: repeat(4, 1fr); gap: 0.75rem;">
          <.swatch name="black-400" var="--zaq-color-black-400" />
          <.swatch name="black-300" var="--zaq-color-black-300" />
          <.swatch name="black-200" var="--zaq-color-black-200" />
          <.swatch name="black-100" var="--zaq-color-black-100" />
        </div>
      </section>

      <section>
        <h2 style="font-size: 0.7rem; font-weight: 600; letter-spacing: 0.1em; text-transform: uppercase; opacity: 0.45; margin-bottom: 1rem;">
          Neutral
        </h2>
        <div style="display: grid; grid-template-columns: repeat(4, 1fr); gap: 0.75rem;">
          <.swatch name="neutral-400" var="--zaq-color-neutral-400" />
          <.swatch name="neutral-300" var="--zaq-color-neutral-300" />
          <.swatch name="neutral-200" var="--zaq-color-neutral-200" />
          <.swatch name="neutral-100" var="--zaq-color-neutral-100" border />
        </div>
      </section>

      <section>
        <h2 style="font-size: 0.7rem; font-weight: 600; letter-spacing: 0.1em; text-transform: uppercase; opacity: 0.45; margin-bottom: 1rem;">
          System
        </h2>
        <div style="display: grid; grid-template-columns: repeat(4, 1fr); gap: 0.75rem;">
          <.swatch name="system-red" var="--zaq-color-system-red" />
          <.swatch name="system-green" var="--zaq-color-system-green" />
          <.swatch name="system-blue" var="--zaq-color-system-blue" />
          <.swatch name="system-orange" var="--zaq-color-system-orange" />
        </div>
      </section>
    </div>
    """
  end

  defp swatch(assigns) do
    ~H"""
    <div style="display: flex; flex-direction: column; gap: 0.4rem;">
      <div style={"height: 48px; border-radius: 8px; background: var(#{@var}); #{if Map.get(assigns, :border), do: "border: 1px solid rgba(0,0,0,0.08);"}"}>
      </div>
      <span style="font-size: 0.7rem; opacity: 0.6; font-family: ui-monospace, monospace;">
        {@name}
      </span>
      <span style="font-size: 0.65rem; opacity: 0.35; font-family: ui-monospace, monospace;">
        {@var}
      </span>
    </div>
    """
  end
end
