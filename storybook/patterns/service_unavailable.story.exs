defmodule Storybook.Patterns.ServiceUnavailable do
  use PhoenixStorybook.Story, :page

  def description, do: "Full-page fallback rendered inside bo_layout when a required OTP service node is unreachable."

  def render(assigns) do
    ~H"""
    <div style="font-family: var(--zaq-font-primary, monospace); padding: 2rem; display: flex; flex-direction: column; gap: 2rem; max-width: 700px;">

      <p style="font-size: 0.75rem; opacity: 0.5; font-family: ui-monospace, monospace;">
        ZaqWeb.Components.ServiceUnavailable.page/1
      </p>

      <p style="font-size: 0.85rem; opacity: 0.6; line-height: 1.6;">
        Renders inside <code style="font-family: ui-monospace, monospace;">bo_layout</code> as a full-page message when <code style="font-family: ui-monospace, monospace;">&#64;service_available</code> is false. Use <code style="font-family: ui-monospace, monospace;">ServiceUnavailable.available?/1</code> in the LiveView mount to check node availability before showing content.
      </p>

      <pre style="background: var(--zaq-color-surface, #faf9f7); border: 1px solid var(--zaq-color-surface-border, #e8e6e1); border-radius: 6px; padding: 1rem; font-size: 0.75rem; overflow-x: auto;"><code>&lt;ZaqWeb.Components.BOLayout.bo_layout &#123;assigns&#125;&gt;
  &lt;%= if &#64;service_available do %&gt;
    &lt;!-- page content --&gt;
  &lt;% else %&gt;
    &lt;ZaqWeb.Components.ServiceUnavailable.page
      current_user=&#123;&#64;current_user&#125;
      current_path=&#123;&#64;current_path&#125;
      page_title="Channels"
      services=&#123;&#64;missing_services&#125;
    /&gt;
  &lt;% end %&gt;
&lt;/ZaqWeb.Components.BOLayout.bo_layout&gt;</code></pre>

      <div style="background: rgba(255,200,60,0.08); border: 1px solid rgba(255,180,0,0.25); border-radius: 8px; padding: 0.75rem 1rem; margin-top: 1rem; font-size: 0.8rem; opacity: 0.7; line-height: 1.6;">
        Live preview not available — <code style="font-family: ui-monospace, monospace;">ServiceUnavailable.page</code> wraps <code style="font-family: ui-monospace, monospace;">bo_layout</code> internally and requires a full LiveView session context. See the pattern in use on any communication page when its service node is down.
      </div>

    </div>
    """
  end
end
