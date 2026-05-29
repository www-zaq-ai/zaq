defmodule Storybook.Patterns.Credentials do
  use PhoenixStorybook.Story, :page

  def description, do: "credential_form — reusable form for OAuth2 and API key credentials. Requires a live form/changeset so it is documented here as a usage pattern."

  def render(assigns) do
    ~H"""
    <div style="font-family: var(--zaq-font-primary, monospace); padding: 2rem; display: flex; flex-direction: column; gap: 2rem; max-width: 700px;">

      <p style="font-size: 0.75rem; opacity: 0.5; font-family: ui-monospace, monospace;">
        ZaqWeb.Components.ConnectCredentialForm.credential_form/1
      </p>

      <p style="font-size: 0.85rem; opacity: 0.6; line-height: 1.6;">
        Use this form whenever creating or editing a Connect integration credential. It handles both OAuth2 (with scope restoration) and API key flows based on the changeset schema.
      </p>

      <pre style="background: var(--zaq-color-surface, #faf9f7); border: 1px solid var(--zaq-color-surface-border, #e8e6e1); border-radius: 6px; padding: 1rem; font-size: 0.75rem; overflow-x: auto;"><code>&lt;ZaqWeb.Components.ConnectCredentialForm.credential_form
  form=&#123;&#64;form&#125;
  changeset=&#123;&#64;changeset&#125;
  errors=&#123;&#64;errors&#125;
  submit_event="save_credential"
  change_event="validate_credential"
  cancel_event="close_credential_form"
  submit_label="Create"
  id_prefix="connect-credential"
/&gt;</code></pre>

      <table style="width: 100%; font-size: 0.8rem; border-collapse: collapse; margin-top: 0.5rem;">
        <thead>
          <tr style="border-bottom: 1px solid var(--zaq-color-surface-border, #e8e6e1);">
            <th style="text-align: left; padding: 0.5rem 0.75rem; opacity: 0.4;">Attr</th>
            <th style="text-align: left; padding: 0.5rem 0.75rem; opacity: 0.4;">Required</th>
            <th style="text-align: left; padding: 0.5rem 0.75rem; opacity: 0.4;">Notes</th>
          </tr>
        </thead>
        <tbody>
          <tr style="border-bottom: 1px solid var(--zaq-color-surface-border, #e8e6e1);">
            <td style="padding: 0.5rem 0.75rem; font-family: ui-monospace, monospace;">form</td>
            <td style="padding: 0.5rem 0.75rem;">yes</td>
            <td style="padding: 0.5rem 0.75rem; opacity: 0.6;">Phoenix form struct</td>
          </tr>
          <tr style="border-bottom: 1px solid var(--zaq-color-surface-border, #e8e6e1);">
            <td style="padding: 0.5rem 0.75rem; font-family: ui-monospace, monospace;">changeset</td>
            <td style="padding: 0.5rem 0.75rem;">yes</td>
            <td style="padding: 0.5rem 0.75rem; opacity: 0.6;">Ecto changeset for the credential schema</td>
          </tr>
          <tr style="border-bottom: 1px solid var(--zaq-color-surface-border, #e8e6e1);">
            <td style="padding: 0.5rem 0.75rem; font-family: ui-monospace, monospace;">submit_event</td>
            <td style="padding: 0.5rem 0.75rem;">yes</td>
            <td style="padding: 0.5rem 0.75rem; opacity: 0.6;">phx-submit event name</td>
          </tr>
          <tr style="border-bottom: 1px solid var(--zaq-color-surface-border, #e8e6e1);">
            <td style="padding: 0.5rem 0.75rem; font-family: ui-monospace, monospace;">change_event</td>
            <td style="padding: 0.5rem 0.75rem;">yes</td>
            <td style="padding: 0.5rem 0.75rem; opacity: 0.6;">phx-change event name for live validation</td>
          </tr>
          <tr style="border-bottom: 1px solid var(--zaq-color-surface-border, #e8e6e1);">
            <td style="padding: 0.5rem 0.75rem; font-family: ui-monospace, monospace;">cancel_event</td>
            <td style="padding: 0.5rem 0.75rem;">yes</td>
            <td style="padding: 0.5rem 0.75rem; opacity: 0.6;">phx-click event for cancel button</td>
          </tr>
          <tr style="border-bottom: 1px solid var(--zaq-color-surface-border, #e8e6e1);">
            <td style="padding: 0.5rem 0.75rem; font-family: ui-monospace, monospace;">submit_label</td>
            <td style="padding: 0.5rem 0.75rem; opacity: 0.5;">no</td>
            <td style="padding: 0.5rem 0.75rem; opacity: 0.6;">Default: "Create"</td>
          </tr>
          <tr>
            <td style="padding: 0.5rem 0.75rem; font-family: ui-monospace, monospace;">restore_scopes_event</td>
            <td style="padding: 0.5rem 0.75rem; opacity: 0.5;">no</td>
            <td style="padding: 0.5rem 0.75rem; opacity: 0.6;">OAuth2 scope restoration event — omit for API key credentials</td>
          </tr>
        </tbody>
      </table>

    </div>
    """
  end
end
