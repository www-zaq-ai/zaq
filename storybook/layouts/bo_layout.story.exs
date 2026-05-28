defmodule Storybook.Layouts.BoLayout do
  use PhoenixStorybook.Story, :page

  def description,
    do:
      "Main back-office shell — collapsible sidebar, fixed header, flash support, and feature-gated navigation. Every BO LiveView must wrap its content in `bo_layout`."

  def render(assigns) do
    ~H"""
    <div style="font-family: var(--zaq-font-primary, monospace); color: var(--zaq-color-ink); padding: 2rem; max-width: 900px;">
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

      <%!-- ── status_badge ─────────────────────────────────── --%>
      <section style="margin-bottom: 3rem;">
        <h2 style="font-size: 1rem; font-weight: 600; margin-bottom: 0.25rem; color: var(--zaq-color-ink);">
          status_badge
        </h2>
        <p style="font-size: 0.875rem; color: var(--zaq-color-ink-soft); margin-bottom: 1rem;">
          Status pill. Accepts <code>:idle</code>, <code>:loading</code>, <code>:ok</code>, or <code>&#123;:error, message&#125;</code>.
        </p>
        <div style="display: flex; gap: 1rem; flex-wrap: wrap; align-items: center;">
          <.labeled_demo label=":idle">
            <ZaqWeb.Components.BOLayout.status_badge status={:idle} />
          </.labeled_demo>
          <.labeled_demo label=":loading">
            <ZaqWeb.Components.BOLayout.status_badge status={:loading} />
          </.labeled_demo>
          <.labeled_demo label=":ok">
            <ZaqWeb.Components.BOLayout.status_badge status={:ok} />
          </.labeled_demo>
          <.labeled_demo label="{:error, msg}">
            <ZaqWeb.Components.BOLayout.status_badge status={{:error, "Connection refused"}} />
          </.labeled_demo>
        </div>
      </section>

      <%!-- ── config_row ──────────────────────────────────── --%>
      <section style="margin-bottom: 3rem;">
        <h2 style="font-size: 1rem; font-weight: 600; margin-bottom: 0.25rem; color: var(--zaq-color-ink);">
          config_row
        </h2>
        <p style="font-size: 0.875rem; color: var(--zaq-color-ink-soft); margin-bottom: 1rem;">
          Label / value display row. Optional <code>:hint</code>
          renders an inline tooltip. <code>:truncate</code>
          clips long values.
        </p>
        <div style="border: 1px solid var(--zaq-color-surface-border); border-radius: 6px; overflow: hidden; max-width: 520px;">
          <ZaqWeb.Components.BOLayout.config_row
            label="API Endpoint"
            value="https://api.example.com/v2"
          />
          <ZaqWeb.Components.BOLayout.config_row
            label="Model"
            value="claude-opus-4-7"
            hint="The default LLM used by all agents."
          />
          <ZaqWeb.Components.BOLayout.config_row
            label="Long token (truncated)"
            value="sk-live-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
            truncate={true}
          />
        </div>
      </section>

      <%!-- ── diagnostic_card ───────────────────────────────── --%>
      <section style="margin-bottom: 3rem;">
        <h2 style="font-size: 1rem; font-weight: 600; margin-bottom: 0.25rem; color: var(--zaq-color-ink);">
          diagnostic_card
        </h2>
        <p style="font-size: 0.875rem; color: var(--zaq-color-ink-soft); margin-bottom: 1rem;">
          Service connection card with a test button. The <code>:event</code>
          attribute triggers a <code>phx-click</code>
          LiveView event.
        </p>
        <div style="display: flex; gap: 1rem; flex-wrap: wrap;">
          <.labeled_demo label="idle">
            <ZaqWeb.Components.BOLayout.diagnostic_card
              label="Database"
              status={:idle}
              event="test_db"
            >
              PostgreSQL connection
            </ZaqWeb.Components.BOLayout.diagnostic_card>
          </.labeled_demo>
          <.labeled_demo label="ok">
            <ZaqWeb.Components.BOLayout.diagnostic_card
              label="Mattermost"
              status={:ok}
              event="test_mm"
            >
              Mattermost webhook
            </ZaqWeb.Components.BOLayout.diagnostic_card>
          </.labeled_demo>
          <.labeled_demo label="error">
            <ZaqWeb.Components.BOLayout.diagnostic_card
              label="SMTP"
              status={{:error, "Timeout"}}
              event="test_smtp"
            >
              Email server
            </ZaqWeb.Components.BOLayout.diagnostic_card>
          </.labeled_demo>
        </div>
      </section>

      <%!-- ── feature_gate ──────────────────────────────────── --%>
      <section style="margin-bottom: 3rem;">
        <h2 style="font-size: 1rem; font-weight: 600; margin-bottom: 0.25rem; color: var(--zaq-color-ink);">
          feature_gate
        </h2>
        <p style="font-size: 0.875rem; color: var(--zaq-color-ink-soft); margin-bottom: 1rem;">
          Full-page placeholder for unlicensed features. Renders an informational card with the feature name. Use as the sole body content inside
          <code>bo_layout</code>
          when the feature flag is disabled.
        </p>
        <div style="border: 1px solid var(--zaq-color-surface-border); border-radius: 6px; padding: 1rem; background: var(--zaq-color-surface);">
          <ZaqWeb.Components.BOLayout.feature_gate feature_name="Ontology" />
        </div>
        <div style="border: 1px solid var(--zaq-color-surface-border); border-radius: 6px; padding: 1rem; background: var(--zaq-color-surface); margin-top: 0.75rem;">
          <ZaqWeb.Components.BOLayout.feature_gate
            feature_name="Knowledge Gap"
            message="Upgrade your license to enable knowledge gap analysis."
          />
        </div>
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

  defp labeled_demo(assigns) do
    ~H"""
    <div style="display: flex; flex-direction: column; gap: 0.4rem; align-items: flex-start;">
      <span style="font-size: 0.7rem; color: var(--zaq-color-ink-soft); font-family: monospace;">
        {@label}
      </span>
      {render_slot(@inner_block)}
    </div>
    """
  end
end
