defmodule Storybook.Layouts.AppLayout do
  use PhoenixStorybook.Story, :page

  def description,
    do:
      "Root app layout shell — `app/1` and `flash_group/1` from `ZaqWeb.Layouts`; theme control via `ZaqWeb.CoreComponents.theme_toggle/1`. Used for public and auth flows (not BO)."

  def render(assigns) do
    ~H"""
    <div style="font-family: var(--zaq-font-primary, monospace); color: var(--zaq-color-ink); padding: 2rem; max-width: 900px;">
      <%!-- ── Preview (default) ─────────────────────────────── --%>
      <section style="margin-bottom: 3rem;">
        <h2 style="font-size: 1rem; font-weight: 600; margin-bottom: 0.5rem; color: var(--zaq-color-ink);">
          Preview
        </h2>
        <p style="font-size: 0.875rem; color: var(--zaq-color-ink-soft); margin-bottom: 1rem; line-height: 1.6;">
          Bounded viewport so the header + main + flash stack matches how the layout behaves in the real app shell (Storybook content area is scroll-clipped like the BO layout story).
        </p>
        <div
          class="zaq-sandbox"
          style="height: 420px; overflow: auto; border-radius: 8px; border: 1px solid var(--zaq-color-surface-border); background: var(--zaq-color-surface, #fff);"
        >
          <ZaqWeb.Layouts.app flash={%{}}>
            <div class="zaq-text-body" style="padding-top: 0.5rem;">
              <p style="margin: 0 0 0.75rem 0; color: var(--zaq-color-ink); font-weight: 600;">
                Sample inner content
              </p>
              <p style="margin: 0; color: var(--zaq-color-ink-soft); font-size: 0.875rem; line-height: 1.5;">
                This block is the page body passed as the default slot to <code style="font-size: 0.8em;">Layouts.app/1</code>. Header shows logo, links, theme toggle, and CTA; flash area is below the main column.
              </p>
            </div>
          </ZaqWeb.Layouts.app>
        </div>
      </section>

      <%!-- ── Preview (with flash) ────────────────────────────── --%>
      <section style="margin-bottom: 3rem;">
        <h2 style="font-size: 1rem; font-weight: 600; margin-bottom: 0.5rem; color: var(--zaq-color-ink);">
          Preview — flash messages
        </h2>
        <p style="font-size: 0.875rem; color: var(--zaq-color-ink-soft); margin-bottom: 1rem;">
          <code>flash_group</code>
          is rendered at the bottom of <code>app/1</code>. Auto-dismiss is left at defaults.
        </p>
        <div
          class="zaq-sandbox"
          style="height: 380px; overflow: auto; border-radius: 8px; border: 1px solid var(--zaq-color-surface-border); background: var(--zaq-color-surface, #fff);"
        >
          <ZaqWeb.Layouts.app flash={
            %{
              "info" => "Check your email to confirm your account.",
              "error" => "Session expired. Sign in again."
            }
          }>
            <p style="margin: 0; color: var(--zaq-color-ink-soft); font-size: 0.875rem;">
              Main column content (flash banners appear below this region).
            </p>
          </ZaqWeb.Layouts.app>
        </div>
      </section>

      <%!-- ── Usage ───────────────────────────────────────────── --%>
      <section style="margin-bottom: 2rem;">
        <h2 style="font-size: 1rem; font-weight: 600; margin-bottom: 0.5rem; color: var(--zaq-color-ink);">
          Usage
        </h2>
        <p style="font-size: 0.875rem; color: var(--zaq-color-ink-soft); margin-bottom: 1rem; line-height: 1.6;">
          Top-level shell for public/auth routes. Back-office pages use
          <code>ZaqWeb.Components.BOLayout.bo_layout</code>
          instead — see the BO Layout story.
        </p>
        <pre style="background: var(--zaq-color-surface, #faf9f7); border: 1px solid var(--zaq-color-surface-border, #e8e6e1); border-radius: 6px; padding: 0.75rem 1rem; font-size: 0.75rem; overflow-x: auto;"><code>&lt;ZaqWeb.Layouts.app flash=&#123;&#64;flash&#125;&gt;
        &lt;%= &#64;inner_content %&gt;
        &lt;/ZaqWeb.Layouts.app&gt;</code></pre>
      </section>

      <section style="margin-bottom: 2rem;">
        <h2 style="font-size: 0.9rem; font-weight: 600; margin-bottom: 0.5rem; color: var(--zaq-color-ink);">
          flash_group/1 alone
        </h2>
        <p style="font-size: 0.8rem; color: var(--zaq-color-ink-soft); margin-bottom: 0.75rem; line-height: 1.6;">
          Normally embedded by <code>app/1</code>. Do <strong>not</strong>
          add it manually inside BO templates — <code>bo_layout</code>
          handles flash there.
        </p>
        <pre style="background: var(--zaq-color-surface, #faf9f7); border: 1px solid var(--zaq-color-surface-border, #e8e6e1); border-radius: 6px; padding: 0.75rem 1rem; font-size: 0.75rem; overflow-x: auto;"><code>&lt;ZaqWeb.Layouts.flash_group flash=&#123;&#64;flash&#125; /&gt;</code></pre>
      </section>

      <section>
        <h2 style="font-size: 0.9rem; font-weight: 600; margin-bottom: 0.5rem; color: var(--zaq-color-ink);">
          theme_toggle/1
        </h2>
        <p style="font-size: 0.8rem; color: var(--zaq-color-ink-soft); margin-bottom: 0.75rem; line-height: 1.6;">
          Included in this layout’s header via <code>CoreComponents.theme_toggle/1</code>. BO header uses the same control from <code>bo_layout</code>.
        </p>
        <pre style="background: var(--zaq-color-surface, #faf9f7); border: 1px solid var(--zaq-color-surface-border, #e8e6e1); border-radius: 6px; padding: 0.75rem 1rem; font-size: 0.75rem; overflow-x: auto;"><code>&lt;ZaqWeb.CoreComponents.theme_toggle /&gt;</code></pre>
      </section>
    </div>
    """
  end
end
