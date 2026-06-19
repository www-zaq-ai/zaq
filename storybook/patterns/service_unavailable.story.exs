defmodule Storybook.Patterns.ServiceUnavailable do
  use PhoenixStorybook.Story, :page

  def description,
    do:
      "Full-page fallback rendered inside bo_layout when a required OTP service node is unreachable."

  def render(assigns) do
    ~H"""
    <div style="font-family: var(--zaq-font-primary, monospace); padding: 2rem; display: flex; flex-direction: column; gap: 2rem; max-width: 900px;">
      <p style="font-size: 0.75rem; opacity: 0.5; font-family: ui-monospace, monospace;">
        ZaqWeb.Components.ServiceUnavailable.page/1 · ZaqWeb.Components.ServiceUnavailable.failure_panel/1
      </p>

      <p style="font-size: 0.85rem; opacity: 0.6; line-height: 1.6;">
        In LiveViews, call
        <code style="font-family: ui-monospace, monospace;">ServiceUnavailable.available?/1</code>
        in <code style="font-family: ui-monospace, monospace;">mount</code>; when false, render
        <code style="font-family: ui-monospace, monospace;">page/1</code>
        so the BO sidebar stays visible. Pass
        <code style="font-family: ui-monospace, monospace;">portal_consent_live_enabled={false}</code>
        only in Storybook to skip the portal LiveComponent.
      </p>

      <section style="display: flex; flex-direction: column; gap: 0.75rem;">
        <h2 style="font-size: 0.85rem; font-weight: 600;">Sample UI — inner panel</h2>
        <p style="font-size: 0.8rem; opacity: 0.65; line-height: 1.5;">
          Fixed missing roles (does not query the cluster). Use for layout and copy review.
        </p>
        <div class="zaq-sandbox rounded-lg border border-black/10 overflow-hidden bg-white">
          <ZaqWeb.Components.ServiceUnavailable.failure_panel missing={[:channels, :agent]} />
        </div>
      </section>

      <section style="display: flex; flex-direction: column; gap: 0.75rem;">
        <h2 style="font-size: 0.85rem; font-weight: 600;">Sample UI — full page in BOLayout</h2>
        <p style="font-size: 0.8rem; opacity: 0.65; line-height: 1.5;">
          Uses your dev cluster to compute which of
          <code style="font-family: ui-monospace, monospace;">services</code>
          are missing; list may be empty if every role is up.
        </p>
        <div
          class="zaq-sandbox rounded-lg border border-black/10 overflow-hidden"
          style="min-height: 24rem;"
        >
          <ZaqWeb.Components.ServiceUnavailable.page
            portal_consent_live_enabled={false}
            current_user={
              %{username: "storybook", role: %{name: "admin"}, portal_consent: nil, email: nil}
            }
            current_path="/bo/channels"
            page_title="Channels"
            services={[:channels, :agent, :ingestion]}
          />
        </div>
      </section>

      <pre style="background: var(--zaq-color-surface, #faf9f7); border: 1px solid var(--zaq-color-surface-border, #e8e6e1); border-radius: 6px; padding: 1rem; font-size: 0.75rem; overflow-x: auto;"><code>&lt;ZaqWeb.Components.BOLayout.bo_layout &#123;assigns&#125;&gt;
      &lt;%= if &#64;service_available do %&gt;
        &lt;!-- page content --&gt;
      &lt;% else %&gt;
        &lt;ZaqWeb.Components.ServiceUnavailable.page
          portal_consent_live_enabled={false}
          current_user=&#123;&#64;current_user&#125;
          current_path=&#123;&#64;current_path&#125;
          page_title="Channels"
          services=&#123;&#64;missing_services&#125;
        /&gt;
      &lt;% end %&gt;
      &lt;/ZaqWeb.Components.BOLayout.bo_layout&gt;</code></pre>
    </div>
    """
  end
end
