defmodule Storybook.Semantic.Layout do
  use PhoenixStorybook.Story, :page
  use Phoenix.Component

  def description,
    do:
      "Role-based layout spacing — --zaq-layout-* tokens and .zaq-layout-* classes in layout.css."

  def render(assigns) do
    ~H"""
    <div
      class="zaq-layout-stack"
      style="font-family: var(--zaq-font-family-body, sans-serif); padding: var(--zaq-scale-32); max-width: 840px;"
    >
      <.callout />

      <section class="zaq-layout-stack-tight">
        <.section_heading title="Class catalog" subtitle="Defined in assets/css/layout.css" />
        <.class_row
          class_name=".zaq-layout-stack"
          token="--zaq-layout-stack-gap"
          px="16px"
          usage="Vertical siblings — page sections, filters → table"
        />
        <.class_row
          class_name=".zaq-layout-stack-tight"
          token="--zaq-layout-stack-gap-tight"
          px="8px"
          usage="Dense vertical lists — label → value"
        />
        <.class_row
          class_name=".zaq-layout-inline"
          token="--zaq-layout-inline-gap"
          px="8px"
          usage="Horizontal toolbar rows — icon + label"
        />
        <.class_row
          class_name=".zaq-layout-inline-compact"
          token="--zaq-layout-inline-gap-compact"
          px="4px"
          usage="Chip / pill clusters"
        />
        <.class_row
          class_name=".zaq-layout-section-gap"
          token="--zaq-layout-section-gap"
          px="24px"
          usage="Gap modifier on grid/flex — major 2-col layouts"
        />
        <.class_row
          class_name=".zaq-layout-grid-gap"
          token="--zaq-layout-grid-gap"
          px="16px"
          usage="Gap modifier on grid — metric cards, widgets"
        />
        <.class_row
          class_name=".zaq-layout-content-inset"
          token="--zaq-layout-content-inset"
          px="24px"
          usage="Padding on inner reading column — chat transcript"
        />
      </section>

      <section class="zaq-layout-stack-tight">
        <.section_heading
          title="Token-only reference"
          subtitle="No utility class — used in BOLayout / feature CSS"
        />
        <.token_only_row
          token="--zaq-layout-page-inset"
          px="32px"
          usage="BOLayout #bo-main padding (p-8)"
        />
        <.token_only_row
          token="--zaq-layout-page-bleed"
          px="32px"
          usage="Full-bleed negative margin (.zaq-chat-page-shell)"
        />
      </section>

      <section class="zaq-layout-stack-tight">
        <.section_heading
          title=".zaq-layout-stack"
          subtitle="gap: var(--zaq-layout-stack-gap) · 16px"
        />
        <.gap_demo class="zaq-layout-stack" direction="column">
          <:cell><.demo_block label="Tabs" /></:cell>
          <:cell><.demo_block label="Filters" /></:cell>
          <:cell><.demo_block label="Table" /></:cell>
        </.gap_demo>
      </section>

      <section class="zaq-layout-stack-tight">
        <.section_heading
          title=".zaq-layout-stack-tight"
          subtitle="gap: var(--zaq-layout-stack-gap-tight) · 8px"
        />
        <.gap_demo class="zaq-layout-stack-tight" direction="column">
          <:cell><.demo_block label="Label" compact /></:cell>
          <:cell><.demo_block label="Value" compact /></:cell>
          <:cell><.demo_block label="Hint" compact /></:cell>
        </.gap_demo>
      </section>

      <section class="zaq-layout-stack-tight">
        <.section_heading
          title=".zaq-layout-inline"
          subtitle="gap: var(--zaq-layout-inline-gap) · 8px"
        />
        <.gap_demo class="zaq-layout-inline" direction="row">
          <:cell><.demo_chip label="Scope" /></:cell>
          <:cell><.demo_chip label="Channel" /></:cell>
          <:cell><.demo_chip label="Team" /></:cell>
        </.gap_demo>
      </section>

      <section class="zaq-layout-stack-tight">
        <.section_heading
          title=".zaq-layout-inline-compact"
          subtitle="gap: var(--zaq-layout-inline-gap-compact) · 4px"
        />
        <.gap_demo class="zaq-layout-inline-compact" direction="row">
          <:cell><.demo_chip label="Public" /></:cell>
          <:cell><.demo_chip label="Shared" /></:cell>
          <:cell><.demo_chip label="Private" /></:cell>
        </.gap_demo>
      </section>

      <section class="zaq-layout-stack-tight">
        <.section_heading title="Grid gap modifiers" subtitle="Apply on grid (or flex) containers" />
        <div class="grid grid-cols-1 md:grid-cols-2 zaq-layout-section-gap">
          <div class="zaq-layout-stack-tight">
            <p class="zaq-text-caption" style="color: var(--zaq-text-color-body-tertiary);">
              .zaq-layout-section-gap · 24px
            </p>
            <.gap_demo class="grid grid-cols-2 zaq-layout-section-gap" direction="grid">
              <:cell><.demo_block label="Col A" compact /></:cell>
              <:cell><.demo_block label="Col B" compact /></:cell>
            </.gap_demo>
          </div>
          <div class="zaq-layout-stack-tight">
            <p class="zaq-text-caption" style="color: var(--zaq-text-color-body-tertiary);">
              .zaq-layout-grid-gap · 16px
            </p>
            <.gap_demo class="grid grid-cols-2 zaq-layout-grid-gap" direction="grid">
              <:cell><.demo_block label="Metric 1" compact /></:cell>
              <:cell><.demo_block label="Metric 2" compact /></:cell>
            </.gap_demo>
          </div>
        </div>
      </section>

      <section class="zaq-layout-stack-tight">
        <.section_heading
          title=".zaq-layout-content-inset"
          subtitle="padding: var(--zaq-layout-content-inset) · 24px"
        />
        <div style="border: var(--zaq-border-thickness-default) dashed var(--zaq-border-color-default); border-radius: var(--zaq-scale-8);">
          <div
            class="zaq-layout-content-inset"
            style="background: var(--zaq-surface-color-accent); border-radius: var(--zaq-scale-8);"
          >
            <.demo_block label="Transcript / reading column content" />
          </div>
        </div>
        <p class="zaq-text-caption" style="color: var(--zaq-text-color-body-tertiary);">
          Dashed border = outer shell. Accent band = padding from .zaq-layout-content-inset.
        </p>
      </section>

      <section class="zaq-layout-stack-tight">
        <.section_heading title="When to use" />
        <ul
          class="zaq-text-body-sm zaq-layout-stack-tight"
          style="color: var(--zaq-text-color-body-secondary); list-style: disc; padding-left: var(--zaq-scale-24);"
        >
          <li>Column siblings → <code>.zaq-layout-stack</code> (+ <code>-tight</code> if dense)</li>
          <li>Row clusters → <code>.zaq-layout-inline</code> (+ <code>-compact</code> for chips)</li>
          <li>Card grid → <code>grid … zaq-layout-grid-gap</code></li>
          <li>2-col page layout → <code>grid … zaq-layout-section-gap</code></li>
          <li>Card shell padding → <code>.zaq-card-default</code></li>
          <li>
            Form / table / modal → <code>form.css</code>, <code>table.css</code>,
            <code>modal.css</code>
          </li>
          <li>
            Structural flex (<code>flex-1</code>, <code>min-w-0</code>) → Tailwind OK; spacing rhythm → layout.css
          </li>
        </ul>
      </section>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :subtitle, :string, default: nil

  defp section_heading(assigns) do
    ~H"""
    <div class="zaq-layout-stack-tight">
      <h2
        class="zaq-text-caption uppercase tracking-widest"
        style="color: var(--zaq-text-color-body-tertiary);"
      >
        {@title}
      </h2>
      <p :if={@subtitle} class="zaq-text-caption" style="color: var(--zaq-text-color-body-tertiary);">
        {@subtitle}
      </p>
    </div>
    """
  end

  defp callout(assigns) do
    ~H"""
    <div
      class="zaq-text-body-sm"
      style="background: var(--zaq-surface-color-accent); border: var(--zaq-border-thickness-default) solid var(--zaq-border-color-accent); border-radius: var(--zaq-scale-8); padding: var(--zaq-scale-16);"
    >
      <strong>layout.css</strong>
      — role-based spacing utilities backed by <code>--zaq-layout-*</code>
      tokens in semantics.css. Never use tokens inline. Legacy 12px / 20px Tailwind converges to <code>--zaq-scale-16</code>.
    </div>
    """
  end

  attr :class_name, :string, required: true
  attr :token, :string, required: true
  attr :px, :string, required: true
  attr :usage, :string, required: true

  defp class_row(assigns) do
    ~H"""
    <div
      class="zaq-text-caption"
      style="display: grid; grid-template-columns: 10rem 12rem 1fr 3rem; gap: var(--zaq-scale-8); align-items: baseline; padding-block: var(--zaq-scale-8); border-bottom: var(--zaq-border-thickness-default) solid var(--zaq-border-color-default);"
    >
      <code style="color: var(--zaq-text-color-body-accent);">{@class_name}</code>
      <code style="color: var(--zaq-text-color-body-tertiary);">{@token}</code>
      <span style="color: var(--zaq-text-color-body-secondary);">{@usage}</span>
      <span style="color: var(--zaq-text-color-body-tertiary); text-align: right;">{@px}</span>
    </div>
    """
  end

  attr :token, :string, required: true
  attr :px, :string, required: true
  attr :usage, :string, required: true

  defp token_only_row(assigns) do
    ~H"""
    <div
      class="zaq-text-caption"
      style="display: grid; grid-template-columns: 11rem 1fr 3rem; gap: var(--zaq-scale-16); align-items: baseline; padding-block: var(--zaq-scale-8); border-bottom: var(--zaq-border-thickness-default) solid var(--zaq-border-color-default);"
    >
      <code style="color: var(--zaq-text-color-body-tertiary);">{@token}</code>
      <span style="color: var(--zaq-text-color-body-secondary);">{@usage}</span>
      <span style="color: var(--zaq-text-color-body-tertiary); text-align: right;">{@px}</span>
    </div>
    """
  end

  attr :class, :string, required: true
  attr :direction, :string, required: true
  slot :cell, required: true

  defp gap_demo(assigns) do
    ~H"""
    <div
      class={@class}
      style="background: var(--zaq-surface-color-accent); border-radius: var(--zaq-scale-8); padding: var(--zaq-scale-16);"
    >
      <%= for cell <- @cell do %>
        {render_slot(cell)}
      <% end %>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :compact, :boolean, default: false

  defp demo_block(assigns) do
    ~H"""
    <div
      class="zaq-text-body-sm"
      style={"background: var(--zaq-surface-color-raised); border: var(--zaq-border-thickness-default) solid var(--zaq-border-color-default); border-radius: var(--zaq-scale-8); padding: #{if @compact, do: "var(--zaq-scale-8)", else: "var(--zaq-scale-16)"};"}
    >
      {@label}
    </div>
    """
  end

  attr :label, :string, required: true

  defp demo_chip(assigns) do
    ~H"""
    <span
      class="zaq-text-caption"
      style="background: var(--zaq-surface-color-raised); border: var(--zaq-border-thickness-default) solid var(--zaq-border-color-default); border-radius: var(--zaq-scale-4); padding: var(--zaq-scale-4) var(--zaq-scale-8);"
    >
      {@label}
    </span>
    """
  end
end
