defmodule Storybook.Foundations.Palette do
  use PhoenixStorybook.Story, :page

  def description,
    do:
      "Raw color palette tokens defined in foundations.css — the source values all semantic tokens map to."

  def render(assigns) do
    ~H"""
    <div style="font-family: var(--zaq-font-family-body, sans-serif); padding: 2rem; display: flex; flex-direction: column; gap: 3rem;">
      <div style="background: rgba(255, 200, 60, 0.1); border: 1px solid rgba(255, 180, 0, 0.3); border-radius: 8px; padding: 0.75rem 1rem; font-size: 0.75rem; line-height: 1.5; color: inherit;">
        <strong style="font-weight: 600;">Foundation tokens are source values only.</strong>
        They exist to define semantic tokens — never reference them directly in components or pages.
        Use <strong style="font-weight: 600;">semantic tokens</strong>
        (e.g. <code style="font-family: ui-monospace, monospace; font-size: 0.8em;">--zaq-surface-color-base</code>, <code style="font-family: ui-monospace, monospace; font-size: 0.8em;">--zaq-border-color-default</code>) in all UI code.
      </div>

      <section>
        <h2 style="font-size: 0.7rem; font-weight: 600; letter-spacing: 0.1em; text-transform: uppercase; opacity: 0.45; margin-bottom: 1rem;">
          Blue
        </h2>
        <div style="display: grid; grid-template-columns: repeat(4, 1fr); gap: 0.75rem;">
          <.swatch name="blue-400" var="--zaq-color-blue-400" usage="→ border/accent" />
          <.swatch name="blue-300" var="--zaq-color-blue-300" usage="→ border/accent" />
          <.swatch name="blue-200" var="--zaq-color-blue-200" usage="→ surface/accent" />
          <.swatch name="blue-100" var="--zaq-color-blue-100" usage="→ surface/accent (light)" />
        </div>
      </section>

      <section>
        <h2 style="font-size: 0.7rem; font-weight: 600; letter-spacing: 0.1em; text-transform: uppercase; opacity: 0.45; margin-bottom: 1rem;">
          Neon
        </h2>
        <div style="display: grid; grid-template-columns: repeat(4, 1fr); gap: 0.75rem;">
          <.swatch
            name="gradient-neon"
            var="--zaq-gradient-neon"
            usage="→ brand identity / logo gradient"
          />
        </div>
      </section>

      <section>
        <h2 style="font-size: 0.7rem; font-weight: 600; letter-spacing: 0.1em; text-transform: uppercase; opacity: 0.45; margin-bottom: 1rem;">
          Black / Ink
        </h2>
        <div style="display: grid; grid-template-columns: repeat(4, 1fr); gap: 0.75rem;">
          <.swatch name="black-400" var="--zaq-color-black-400" usage="→ text/body/default" />
          <.swatch name="black-300" var="--zaq-color-black-300" usage="→ surface/dark (sidebar)" />
          <.swatch name="black-200" var="--zaq-color-black-200" usage="→ text/body/secondary" />
          <.swatch name="black-100" var="--zaq-color-black-100" usage="→ text/body/tertiary" />
        </div>
      </section>

      <section>
        <h2 style="font-size: 0.7rem; font-weight: 600; letter-spacing: 0.1em; text-transform: uppercase; opacity: 0.45; margin-bottom: 1rem;">
          Neutral
        </h2>
        <div style="display: grid; grid-template-columns: repeat(4, 1fr); gap: 0.75rem;">
          <.swatch name="neutral-400" var="--zaq-color-neutral-400" usage="→ border/strong" />
          <.swatch
            name="neutral-300"
            var="--zaq-color-neutral-300"
            usage="→ border/default, surface/elevated"
          />
          <.swatch name="neutral-200" var="--zaq-color-neutral-200" usage="→ surface/base" />
          <.swatch
            name="neutral-100"
            var="--zaq-color-neutral-100"
            border
            usage="→ surface/raised, text/body/invert"
          />
        </div>
      </section>

      <section>
        <h2 style="font-size: 0.7rem; font-weight: 600; letter-spacing: 0.1em; text-transform: uppercase; opacity: 0.45; margin-bottom: 1rem;">
          System
        </h2>
        <div style="display: grid; grid-template-columns: repeat(4, 1fr); gap: 0.75rem;">
          <.swatch name="system-red" var="--zaq-color-system-red" usage="→ border/error" />
          <.swatch name="system-green" var="--zaq-color-system-green" usage="→ success states" />
          <.swatch name="system-blue" var="--zaq-color-system-blue" usage="→ info states" />
          <.swatch name="system-orange" var="--zaq-color-system-orange" usage="→ warning states" />
        </div>
      </section>
    </div>
    """
  end

  defp swatch(assigns) do
    assigns = Map.put_new(assigns, :usage, nil)

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
      <%= if @usage do %>
        <span style="font-size: 0.6rem; opacity: 0.4; font-family: ui-monospace, monospace; font-style: italic;">
          {@usage}
        </span>
      <% end %>
    </div>
    """
  end
end
