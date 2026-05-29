defmodule Storybook.Layouts.AppLayout do
  use PhoenixStorybook.Story, :page

  def description, do: "Root app layout shell — app/1, flash_group/1, and theme_toggle/1 from ZaqWeb.Layouts."

  def render(assigns) do
    ~H"""
    <div style="font-family: var(--zaq-font-primary, monospace); padding: 2rem; display: flex; flex-direction: column; gap: 3rem; max-width: 800px;">

      <section>
        <h2 style="font-size: 0.9rem; font-weight: 600; margin-bottom: 0.5rem;">app/1</h2>
        <p style="font-size: 0.8rem; opacity: 0.6; line-height: 1.6; margin-bottom: 1rem;">
          Top-level layout shell used for the public-facing and authentication flows. Wraps <code style="font-family: ui-monospace, monospace;">flash_group</code> and the page content. BO pages use <code style="font-family: ui-monospace, monospace;">BOLayout.bo_layout</code> instead.
        </p>
        <pre style="background: var(--zaq-color-surface, #faf9f7); border: 1px solid var(--zaq-color-surface-border, #e8e6e1); border-radius: 6px; padding: 0.75rem 1rem; font-size: 0.75rem; overflow-x: auto;"><code>&lt;!-- lib/zaq_web/components/layouts/app.html.heex --&gt;
&lt;ZaqWeb.Layouts.app flash=&#123;&#64;flash&#125;&gt;
  &lt;%= &#64;inner_content %&gt;
&lt;/ZaqWeb.Layouts.app&gt;</code></pre>
      </section>

      <section>
        <h2 style="font-size: 0.9rem; font-weight: 600; margin-bottom: 0.5rem;">flash_group/1</h2>
        <p style="font-size: 0.8rem; opacity: 0.6; line-height: 1.6; margin-bottom: 1rem;">
          Renders a stack of flash messages from the Phoenix flash map. Used automatically inside <code style="font-family: ui-monospace, monospace;">app/1</code>. Do <strong>not</strong> add it manually inside BO templates — <code style="font-family: ui-monospace, monospace;">bo_layout</code> handles flash internally.
        </p>
        <pre style="background: var(--zaq-color-surface, #faf9f7); border: 1px solid var(--zaq-color-surface-border, #e8e6e1); border-radius: 6px; padding: 0.75rem 1rem; font-size: 0.75rem; overflow-x: auto;"><code>&lt;ZaqWeb.Layouts.flash_group flash=&#123;&#64;flash&#125; /&gt;</code></pre>
      </section>

      <section>
        <h2 style="font-size: 0.9rem; font-weight: 600; margin-bottom: 0.5rem;">theme_toggle/1</h2>
        <p style="font-size: 0.8rem; opacity: 0.6; line-height: 1.6; margin-bottom: 1rem;">
          Light/dark theme switcher button. Included in the BO header via <code style="font-family: ui-monospace, monospace;">bo_layout</code>.
        </p>
        <pre style="background: var(--zaq-color-surface, #faf9f7); border: 1px solid var(--zaq-color-surface-border, #e8e6e1); border-radius: 6px; padding: 0.75rem 1rem; font-size: 0.75rem; overflow-x: auto;"><code>&lt;ZaqWeb.Layouts.theme_toggle /&gt;</code></pre>
      </section>

    </div>
    """
  end
end
