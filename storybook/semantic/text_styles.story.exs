defmodule Storybook.Semantic.TextStyles do
  use PhoenixStorybook.Story, :page

  def description,
    do:
      "Semantic text style classes — apply a single class to get font, size, weight, line-height, and letter-spacing."

  def render(assigns) do
    ~H"""
    <div style="padding: 2rem; display: flex; flex-direction: column; gap: 3rem; max-width: 760px;">
      
    <!-- Heading scale -->
      <section>
        <h2 style="font-size: 0.7rem; font-weight: 600; letter-spacing: 0.1em; text-transform: uppercase; opacity: 0.45; margin-bottom: 1.5rem;">
          Heading Scale
        </h2>
        <div style="display: flex; flex-direction: column; gap: 1rem;">
          <.type_row
            class_name="zaq-text-h1"
            tokens="Hanken Grotesk · 24px · 600 · lh 1.4"
            sample="Page title"
          />
          <.type_row
            class_name="zaq-text-h2"
            tokens="Hanken Grotesk · 20px · 600 · lh 1.2"
            sample="Section heading"
          />
          <.type_row
            class_name="zaq-text-h3"
            tokens="Hanken Grotesk · 16px · 600 · lh 1.2"
            sample="Subsection"
          />
          <.type_row
            class_name="zaq-text-h4"
            tokens="Hanken Grotesk · 14px · 600 · lh 1.2"
            sample="Card title"
          />
          <.type_row
            class_name="zaq-text-h5"
            tokens="Hanken Grotesk · 12px · 600 · lh 1.2"
            sample="Label heading"
          />
        </div>
      </section>
      
    <!-- Body scale -->
      <section>
        <h2 style="font-size: 0.7rem; font-weight: 600; letter-spacing: 0.1em; text-transform: uppercase; opacity: 0.45; margin-bottom: 1.5rem;">
          Body Scale
        </h2>
        <div style="display: flex; flex-direction: column; gap: 1rem;">
          <.type_row
            class_name="zaq-text-body-lg"
            tokens="Inter · 16px · 400 · lh 1.6"
            sample="The quick brown fox jumps over the lazy dog."
          />
          <.type_row
            class_name="zaq-text-body"
            tokens="Inter · 14px · 400 · lh 1.6"
            sample="The quick brown fox jumps over the lazy dog."
          />
          <.type_row
            class_name="zaq-text-body-sm"
            tokens="Inter · 12px · 400 · lh 1.6"
            sample="The quick brown fox jumps over the lazy dog."
          />
          <.type_row
            class_name="zaq-text-caption"
            tokens="Inter · 10px · 400 · lh 1.6 · ls 0.1em"
            sample="Metadata, helper text, timestamps."
          />
        </div>
      </section>
      
    <!-- Code & Monospace -->
      <section>
        <h2 style="font-size: 0.7rem; font-weight: 600; letter-spacing: 0.1em; text-transform: uppercase; opacity: 0.45; margin-bottom: 1.5rem;">
          Code &amp; Monospace
        </h2>
        <div style="display: flex; flex-direction: column; gap: 1rem;">
          <.type_row
            class_name="zaq-text-code"
            tokens="JetBrains Mono · 12px · 400 · lh relaxed"
            sample="inline code snippet"
          />
          <.type_row
            class_name="zaq-text-pre"
            tokens="JetBrains Mono · 14px · 400 · lh 1.6"
            sample="def greet(name), do: IO.puts(name)"
          />
        </div>
      </section>
    </div>
    """
  end

  defp type_row(assigns) do
    ~H"""
    <div style="display: flex; flex-direction: column; gap: 0.2rem; padding-bottom: 1rem; border-bottom: 1px solid rgba(0,0,0,0.05);">
      <span class={@class_name}>
        {@sample}
      </span>
      <div style="display: flex; align-items: center; gap: 0.5rem; margin-top: 0.15rem;">
        <code style="font-family: ui-monospace, monospace; font-size: 0.7rem; background: rgba(0,0,0,0.05); border-radius: 4px; padding: 0.1em 0.45em; color: inherit;">
          .{@class_name}
        </code>
        <span style="font-family: ui-monospace, monospace; font-size: 0.65rem; opacity: 0.35;">
          {@tokens}
        </span>
      </div>
    </div>
    """
  end
end
