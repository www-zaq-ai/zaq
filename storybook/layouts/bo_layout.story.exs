defmodule Storybook.Layouts.BoLayout do
  use PhoenixStorybook.Story, :page

  def description,
    do:
      "Main back-office shell — collapsible sidebar, fixed header, flash support, and feature-gated navigation. Every BO LiveView must wrap its content in `bo_layout`."

  def render(assigns) do
    ~H"""
    <div style="font-family: var(--zaq-font-primary, monospace); color: var(--zaq-color-ink); padding: 2rem; max-width: 900px;">
      <%!-- ── Preview ────────────────────────────────────────── --%>
      <section style="margin-bottom: 3rem;">
        <h2 style="font-size: 1rem; font-weight: 600; margin-bottom: 0.5rem; color: var(--zaq-color-ink);">
          Preview
        </h2>
        <div style="height: 500px; overflow: hidden; border-radius: 8px; border: 1px solid var(--zaq-color-surface-border); position: relative;">
          <ZaqWeb.Components.BOLayout.bo_layout
            current_user={%{username: "Admin"}}
            page_title="Dashboard"
            current_path="/bo/dashboard"
            flash={%{}}
            update_badge_enabled={true}
          >
            <div style="padding: 2rem; color: var(--zaq-color-ink-soft);">
              ← Sidebar visible on the left. Update badge visible in the footer.
            </div>
          </ZaqWeb.Components.BOLayout.bo_layout>
        </div>
      </section>

      <%!-- ── Flash States ───────────────────────────────────── --%>
      <section style="margin-bottom: 3rem;">
        <h2 style="font-size: 1rem; font-weight: 600; margin-bottom: 0.5rem; color: var(--zaq-color-ink);">
          Flash States
        </h2>
        <p style="font-size: 0.875rem; color: var(--zaq-color-ink-soft); margin-bottom: 1rem;">
          Inline flash banners rendered inside the layout content area. Auto-dismiss is disabled so they remain visible.
        </p>
        <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 1rem;">
          <div>
            <p style="font-size: 0.75rem; font-weight: 600; color: var(--zaq-color-ink-soft); margin-bottom: 0.5rem; text-transform: uppercase; letter-spacing: 0.05em;">
              Info / Success
            </p>
            <div style="height: 160px; overflow: hidden; border-radius: 8px; border: 1px solid var(--zaq-color-surface-border);">
              <ZaqWeb.Components.BOLayout.bo_layout
                current_user={%{username: "Admin"}}
                page_title="Dashboard"
                current_path="/bo/dashboard"
                flash={%{"info" => "Settings saved successfully."}}
                auto_dismiss={false}
                update_badge_enabled={false}
              >
                <div />
              </ZaqWeb.Components.BOLayout.bo_layout>
            </div>
          </div>
          <div>
            <p style="font-size: 0.75rem; font-weight: 600; color: var(--zaq-color-ink-soft); margin-bottom: 0.5rem; text-transform: uppercase; letter-spacing: 0.05em;">
              Error
            </p>
            <div style="height: 160px; overflow: hidden; border-radius: 8px; border: 1px solid var(--zaq-color-surface-border);">
              <ZaqWeb.Components.BOLayout.bo_layout
                current_user={%{username: "Admin"}}
                page_title="Dashboard"
                current_path="/bo/dashboard"
                flash={%{"error" => "An unexpected error occurred. Please try again."}}
                auto_dismiss={false}
                update_badge_enabled={false}
              >
                <div />
              </ZaqWeb.Components.BOLayout.bo_layout>
            </div>
          </div>
        </div>
      </section>

      <%!-- ── Usage ─────────────────────────────────────────── --%>
      <section style="margin-bottom: 3rem;">
        <h2 style="font-size: 1rem; font-weight: 600; margin-bottom: 0.5rem; color: var(--zaq-color-ink);">
          Usage
        </h2>
        <p style="font-size: 0.875rem; color: var(--zaq-color-ink-soft); margin-bottom: 1rem;">
          Wrap every BO LiveView template with <code>bo_layout</code>. It provides the sidebar, header, flash messages, and layout structure.
        </p>
        <pre style="background: var(--zaq-color-surface); border: 1px solid var(--zaq-color-surface-border); border-radius: 6px; padding: 1rem; font-size: 0.8rem; overflow-x: auto;"><code>&lt;ZaqWeb.Components.BOLayout.bo_layout
  current_user=&#123;@current_user&#125;
  flash=&#123;@flash&#125;
  page_title="Dashboard"
  current_path=&#123;@current_path&#125;
  features_version=&#123;@features_version&#125;
&gt;
  &lt;!-- your page content here --&gt;
&lt;/ZaqWeb.Components.BOLayout.bo_layout&gt;</code></pre>
      </section>

      <%!-- ── Attributes ───────────────────────────────────── --%>
      <section style="margin-bottom: 3rem;">
        <h2 style="font-size: 1rem; font-weight: 600; margin-bottom: 1rem; color: var(--zaq-color-ink);">
          Attributes
        </h2>
        <table style="width: 100%; font-size: 0.8rem; border-collapse: collapse;">
          <thead>
            <tr style="border-bottom: 1px solid var(--zaq-color-surface-border);">
              <th style="text-align: left; padding: 0.5rem 0.75rem; color: var(--zaq-color-ink-soft);">
                Name
              </th>
              <th style="text-align: left; padding: 0.5rem 0.75rem; color: var(--zaq-color-ink-soft);">
                Type
              </th>
              <th style="text-align: left; padding: 0.5rem 0.75rem; color: var(--zaq-color-ink-soft);">
                Default
              </th>
              <th style="text-align: left; padding: 0.5rem 0.75rem; color: var(--zaq-color-ink-soft);">
                Description
              </th>
            </tr>
          </thead>
          <tbody>
            <.attr_row
              name="current_user"
              type="map"
              required={true}
              default="—"
              description="Current user. Must have a :username key."
            />
            <.attr_row
              name="page_title"
              type="string"
              required={false}
              default={~s("Dashboard")}
              description="Title shown in the fixed header."
            />
            <.attr_row
              name="current_path"
              type="string"
              required={false}
              default={~s("")}
              description={~s(Request path for active nav highlighting, e.g. "/bo/dashboard".)}
            />
            <.attr_row
              name="flash"
              type="map"
              required={false}
              default="%{}"
              description="Phoenix flash messages (info / error)."
            />
            <.attr_row
              name="auto_dismiss"
              type="boolean"
              required={false}
              default="true"
              description="Auto-dismiss flash messages."
            />
            <.attr_row
              name="auto_dismiss_duration"
              type="integer"
              required={false}
              default="5000"
              description="Delay before flash is dismissed (ms)."
            />
            <.attr_row
              name="features_version"
              type="integer"
              required={false}
              default="0"
              description="Feature flag version for license-checking nav items."
            />
            <.attr_row
              name="update_badge_enabled"
              type="boolean"
              required={false}
              default="nil"
              description="Show version update badge. Auto-loaded from DB when nil."
            />
          </tbody>
        </table>
      </section>

      <%!-- ── Sub-components ─────────────────────────────────── --%>
      <section style="margin-bottom: 3rem;">
        <h2 style="font-size: 1rem; font-weight: 600; margin-bottom: 0.5rem; color: var(--zaq-color-ink);">
          Sub-components
        </h2>
        <p style="font-size: 0.875rem; color: var(--zaq-color-ink-soft); line-height: 1.6;">
          <code>BOLayout</code> also exports reusable atomic components — documented individually in their own stories:
        </p>
        <ul style="font-size: 0.875rem; color: var(--zaq-color-ink-soft); margin-top: 0.75rem; line-height: 2;">
          <li><code>status_badge</code> → Components / Feedback / Status Badge</li>
          <li><code>config_row</code> → Components / Misc / Config Row</li>
          <li><code>diagnostic_card</code> → Components / Misc / Diagnostic Card</li>
          <li><code>feature_gate</code> → Patterns / Feature Gate</li>
        </ul>
      </section>
    </div>
    """
  end

  defp attr_row(assigns) do
    ~H"""
    <tr style="border-bottom: 1px solid var(--zaq-color-surface-border);">
      <td style="padding: 0.5rem 0.75rem; font-weight: 500;">
        {@name}
        <%= if @required do %>
          <span style="color: #e53e3e; margin-left: 2px;">*</span>
        <% end %>
      </td>
      <td style="padding: 0.5rem 0.75rem; color: var(--zaq-color-accent); font-size: 0.75rem;">
        {@type}
      </td>
      <td style="padding: 0.5rem 0.75rem; color: var(--zaq-color-ink-soft); font-size: 0.75rem;">
        {@default}
      </td>
      <td style="padding: 0.5rem 0.75rem; color: var(--zaq-color-ink-soft);">{@description}</td>
    </tr>
    """
  end

end
