defmodule Storybook.Semantic.TextStylesDeprecated do
  use PhoenixStorybook.Story, :page

  def description,
    do: "Deprecated text styles — superseded by the zaq-text-* CSS class system."

  def render(assigns) do
    ~H"""
    <div style="font-family: var(--zaq-font-primary, sans-serif); padding: 2rem; display: flex; flex-direction: column; gap: 3rem; max-width: 760px;">
      <div style="background: rgba(234, 0, 62, 0.06); border: 1px solid rgba(234, 0, 62, 0.25); border-radius: 8px; padding: 0.75rem 1rem; font-size: 0.75rem; line-height: 1.5; color: inherit;">
        <strong style="font-weight: 600;">⚠ Deprecated.</strong>
        These styles are no longer the source of truth.
        Use the
        <code style="font-family: ui-monospace, monospace; font-size: 0.8em;">.zaq-text-*</code>
        CSS classes defined in <strong style="font-weight: 600;">Semantics / Text Styles</strong>
        instead.
      </div>
      
    <!-- Heading scale -->
      <section>
        <h2 style="font-size: 0.7rem; font-weight: 600; letter-spacing: 0.1em; text-transform: uppercase; opacity: 0.45; margin-bottom: 1.5rem;">
          Heading Scale
        </h2>
        <div style="display: flex; flex-direction: column; gap: 1rem;">
          <.type_row
            class_name="h1"
            label="H1 · 2rem / 700"
            style="font-size: 2rem; font-weight: 700; line-height: 1.2;"
            sample="Page title"
          />
          <.type_row
            class_name="h2"
            label="H2 · 1.5rem / 600"
            style="font-size: 1.5rem; font-weight: 600; line-height: 1.3;"
            sample="Section heading"
          />
          <.type_row
            class_name="h3"
            label="H3 · 1.25rem / 600"
            style="font-size: 1.25rem; font-weight: 600; line-height: 1.35;"
            sample="Subsection"
          />
          <.type_row
            class_name="h4"
            label="H4 · 1rem / 600"
            style="font-size: 1rem; font-weight: 600; line-height: 1.4;"
            sample="Card title"
          />
          <.type_row
            class_name="h5"
            label="H5 · 0.875rem / 600"
            style="font-size: 0.875rem; font-weight: 600; line-height: 1.4;"
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
            class_name="body-lg"
            label="body-lg · 1rem / 400"
            style="font-size: 1rem; font-weight: 400; line-height: 1.6;"
            sample="The quick brown fox jumps over the lazy dog."
          />
          <.type_row
            class_name="body"
            label="body · 0.875rem / 400"
            style="font-size: 0.875rem; font-weight: 400; line-height: 1.6;"
            sample="The quick brown fox jumps over the lazy dog."
          />
          <.type_row
            class_name="body-sm"
            label="body-sm · 0.8125rem / 400"
            style="font-size: 0.8125rem; font-weight: 400; line-height: 1.55;"
            sample="The quick brown fox jumps over the lazy dog."
          />
          <.type_row
            class_name="caption"
            label="caption · 0.75rem / 400"
            style="font-size: 0.75rem; font-weight: 400; line-height: 1.5; opacity: 0.6;"
            sample="Metadata, helper text, timestamps."
          />
        </div>
      </section>
      
    <!-- Code & Monospace -->
      <section>
        <h2 style="font-size: 0.7rem; font-weight: 600; letter-spacing: 0.1em; text-transform: uppercase; opacity: 0.45; margin-bottom: 1.5rem;">
          Code &amp; Monospace
        </h2>
        <div style="display: flex; flex-direction: column; gap: 0.75rem;">
          <div style="display: flex; flex-direction: column; gap: 0.2rem; padding-bottom: 1rem; border-bottom: 1px solid rgba(0,0,0,0.05);">
            <code style="font-family: ui-monospace, monospace; font-size: 0.82em; background: rgba(0,0,0,0.04); padding: 0.15em 0.4em; border-radius: 4px; display: inline-block;">
              inline code snippet
            </code>
            <div style="display: flex; align-items: center; gap: 0.5rem; margin-top: 0.15rem;">
              <code style="font-family: ui-monospace, monospace; font-size: 0.7rem; background: rgba(0,0,0,0.05); border-radius: 4px; padding: 0.1em 0.45em; color: inherit;">
                code
              </code>
              <span style="font-family: ui-monospace, monospace; font-size: 0.65rem; opacity: 0.35;">
                inline · ui-monospace / 0.82em
              </span>
            </div>
          </div>
          <div style="display: flex; flex-direction: column; gap: 0.2rem;">
            <pre style="background: #1a1a1a; color: #e5e5e5; padding: 1.25em 1.5em; border-radius: 12px; overflow-x: auto; font-family: ui-monospace, monospace; font-size: 0.85em; line-height: 1.6;">def hello(name), do: "Hello, " &lt;&gt; name &lt;&gt; "!"</pre>
            <div style="display: flex; align-items: center; gap: 0.5rem; margin-top: 0.15rem;">
              <code style="font-family: ui-monospace, monospace; font-size: 0.7rem; background: rgba(0,0,0,0.05); border-radius: 4px; padding: 0.1em 0.45em; color: inherit;">
                pre
              </code>
              <span style="font-family: ui-monospace, monospace; font-size: 0.65rem; opacity: 0.35;">
                block · ui-monospace / 0.85em
              </span>
            </div>
          </div>
        </div>
      </section>
    </div>
    """
  end

  defp type_row(assigns) do
    ~H"""
    <div style="display: flex; flex-direction: column; gap: 0.2rem; padding-bottom: 1rem; border-bottom: 1px solid rgba(0,0,0,0.05);">
      <span style={"font-family: var(--zaq-font-primary, sans-serif); color: var(--zaq-color-ink, #2c3a50); #{@style}"}>
        {@sample}
      </span>
      <div style="display: flex; align-items: center; gap: 0.5rem; margin-top: 0.15rem;">
        <code style="font-family: ui-monospace, monospace; font-size: 0.7rem; background: rgba(0,0,0,0.05); border-radius: 4px; padding: 0.1em 0.45em; color: inherit;">
          .{@class_name}
        </code>
        <span style="font-family: ui-monospace, monospace; font-size: 0.65rem; opacity: 0.35;">
          {@label}
        </span>
      </div>
    </div>
    """
  end
end
