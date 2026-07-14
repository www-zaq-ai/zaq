defmodule Storybook.Modals.BoModal do
  use PhoenixStorybook.Story, :page
  use Phoenix.Component

  import ZaqWeb.Components.BOModal
  import ZaqWeb.Components.DesignSystem.Button
  import ZaqWeb.Components.DesignSystem.Input

  @cancel_event "storybook_close_modal"
  @module "ZaqWeb.Components.BOModal"
  @iframe_demo_src "data:text/html;charset=utf-8," <>
                     URI.encode("""
                     <!DOCTYPE html>
                     <html>
                       <body style="margin:0;padding:1.5rem;font-family:system-ui,sans-serif;background:#eff6ff;color:#1e3a5f">
                         <p style="margin:0 0 0.5rem;font-weight:600">Authorize ZAQ</p>
                         <p style="margin:0;font-size:0.875rem;line-height:1.5">
                           Mock OAuth consent screen for Storybook preview.
                         </p>
                       </body>
                     </html>
                     """)

  def description do
    """
    Back-office modal primitives (`#{@module}`). Scroll this page for a decision guide, attribute reference, usage snippets, and bounded previews for each function.
    """
    |> String.trim()
  end

  def render(assigns) do
    assigns =
      assigns
      |> assign(:cancel_event, @cancel_event)
      |> assign(:iframe_demo_src, @iframe_demo_src)

    ~H"""
    <div
      class="zaq-text-body zaq-sandbox"
      style="padding: var(--zaq-scale-32); max-width: 52rem; display: flex; flex-direction: column; gap: var(--zaq-scale-48);"
    >
      <.intro_section />
      <.doc_section
        id="modal-shell"
        title="modal_shell/1"
        when_to_use="Low-level wrapper for custom modal bodies. Uses `modal.css` tokens (`zaq-bo-modal-backdrop`, `zaq-modal`). Pass optional `title` for the shared `.zaq-modal-header` row (same as `form_dialog/1`). Prefer `form_dialog/1` for standard add/edit popins with a footer."
        rows={modal_shell_rows()}
        code={modal_shell_usage()}
      >
        <.preview_frame label="Default — centered panel (`zaq-modal--width-sm`)">
          <.modal_shell id="sb-shell-default" cancel_event={@cancel_event}>
            <p class="zaq-text-body-sm text-center" style="color: var(--zaq-text-color-body-tertiary)">
              Pass any markup in the inner block.
            </p>
          </.modal_shell>
        </.preview_frame>
        <.preview_frame label="Titled shell — shared `.zaq-modal-header` + scroll body">
          <.modal_shell
            id="sb-shell-titled"
            cancel_event={@cancel_event}
            title="Add MCP endpoint"
            max_width_class="zaq-modal--width-lg"
          >
            <p class="zaq-text-body-sm" style="color: var(--zaq-text-color-body-tertiary)">
              Body content uses `.zaq-modal-body` padding when `title` is set.
            </p>
          </.modal_shell>
        </.preview_frame>
        <.preview_frame label="Flush panel — zaq-modal--flush on panel_base_class">
          <.modal_shell
            id="sb-shell-flush"
            cancel_event={@cancel_event}
            max_width_class="zaq-modal--width-md"
            panel_base_class="zaq-modal zaq-modal--flush"
          >
            <div class="zaq-file-preview-bar">
              <p class="zaq-text-h4">Toolbar</p>
            </div>
            <div class="zaq-file-preview-scroll">
              <p class="zaq-text-body-sm" style="color: var(--zaq-text-color-body-tertiary)">
                Edge-to-edge content (file preview, tables).
              </p>
            </div>
          </.modal_shell>
        </.preview_frame>
      </.doc_section>

      <.doc_section
        id="confirm-dialog"
        title="confirm_dialog/1"
        when_to_use="Destructive confirmations before delete/remove. Wraps `modal_shell/1` with trash icon, title, message, and Cancel / Confirm buttons."
        rows={confirm_dialog_rows()}
        code={confirm_dialog_usage()}
      >
        <.preview_frame label="Default delete">
          <.confirm_dialog
            id="sb-confirm-default"
            title="Delete document"
            message="This action cannot be undone. The document will be permanently deleted."
            cancel_event={@cancel_event}
            confirm_event="delete"
          />
        </.preview_frame>
        <.preview_frame label="Custom labels + width (`max-w-md`)">
          <.confirm_dialog
            id="sb-confirm-custom"
            title="Remove member"
            message="Jana Abiakar will lose access to this workspace."
            cancel_event={@cancel_event}
            confirm_event="remove_member"
            confirm_label="Remove"
            cancel_label="Keep member"
            max_width_class="max-w-md"
          />
        </.preview_frame>
      </.doc_section>

      <.doc_section
        id="form-dialog"
        title="form_dialog/1"
        when_to_use="Default for BO add/edit dialogs. Composes `modal_shell/1` with titled header, scrollable body (`zaq-modal--form`), and optional `:actions` slot. Use `DesignSystem.Input`, `DesignSystem.Button`, and other DS form modules in the body — see Ingestion `ModalUpload` for a composed example."
        rows={form_dialog_rows()}
        code={form_dialog_usage()}
      >
        <.preview_frame
          label="With `:actions` slot — DS body + footer buttons"
          class="zaq-modal-preview--tall"
        >
          <.form_dialog
            id="sb-form-actions"
            cancel_event={@cancel_event}
            title="Edit workspace"
            max_width_class="zaq-modal--width-lg"
          >
            <form id="sb-workspace-form" class="zaq-layout-stack">
              <p class="zaq-text-body-sm" style="color: var(--zaq-text-color-body-tertiary)">
                Body scrolls when content exceeds the viewport. Footer actions stay pinned.
              </p>
              <.input
                id="sb-workspace-name"
                name="workspace[name]"
                label="Name"
                value="Engineering workspace"
              />
              <.input
                id="sb-workspace-description"
                name="workspace[description]"
                type="textarea"
                label="Description"
                value="Shared docs and ingestion for the engineering team."
                rows="3"
              />
            </form>
            <:actions>
              <.button type="button" variant={:secondary} phx-click={@cancel_event}>
                Cancel
              </.button>
              <.button type="submit" variant={:primary} form="sb-workspace-form">
                Save
              </.button>
            </:actions>
          </.form_dialog>
        </.preview_frame>
        <.preview_frame label="Body only — form owns its footer (omit `:actions`)">
          <.form_dialog
            id="sb-form-body-only"
            cancel_event={@cancel_event}
            title="Rename folder"
            max_width_class="zaq-modal--width-sm"
          >
            <form id="sb-rename-form" class="zaq-layout-stack">
              <.input
                id="sb-folder-name"
                name="folder[name]"
                label="Name"
                value="Q1 reports"
              />
              <div class="zaq-modal-form-actions">
                <.button type="button" variant={:secondary} phx-click={@cancel_event}>
                  Cancel
                </.button>
                <.button type="submit" variant={:primary}>
                  Rename
                </.button>
              </div>
            </form>
          </.form_dialog>
        </.preview_frame>
      </.doc_section>

      <.doc_section
        id="iframe-dialog"
        title="iframe_dialog/1"
        when_to_use="OAuth grants and embedded external UIs. Composes `modal_shell/1` with title bar, close button, and sized iframe."
        rows={iframe_dialog_rows()}
        code={iframe_dialog_usage()}
      >
        <.preview_frame label="OAuth-style embed" class="zaq-modal-preview--tall">
          <.iframe_dialog
            id="sb-iframe-oauth"
            cancel_event={@cancel_event}
            title="OAuth2 authorization"
            src={@iframe_demo_src}
          />
        </.preview_frame>
      </.doc_section>

      <section style="display: flex; flex-direction: column; gap: var(--zaq-scale-12);">
        <h2 class="zaq-text-heading" style="font-size: 1rem; margin: 0;">
          LiveView integration
        </h2>
        <ul
          class="zaq-text-caption"
          style="color: var(--zaq-text-color-body-secondary); margin: 0; padding-left: 1.25rem; line-height: 1.7;"
        >
          <li>
            Always pass a
            <code style="font-family: var(--zaq-font-family-code, ui-monospace, monospace);">
              cancel_event
            </code>
            string — fired on backdrop click and Escape (<code>phx-window-keydown</code>).
          </li>
          <li>
            Render modals conditionally with <code>:if=&#123;@show_modal?&#125;</code>
            from LiveView assign state.
          </li>
          <li>
            Domain-specific modals (ingestion delete, share, etc.) compose these primitives — see Ingestion stories.
          </li>
          <li>
            In Storybook, <code>phx-click</code>
            handlers are inert (no socket). Previews use bounded frames; production uses full-viewport
            <code>fixed</code>
            positioning.
          </li>
        </ul>
      </section>
    </div>
    """
  end

  defp intro_section(assigns) do
    assigns = assign(assigns, :module, @module)

    ~H"""
    <section style="display: flex; flex-direction: column; gap: var(--zaq-scale-16);">
      <div style="display: flex; flex-direction: column; gap: var(--zaq-scale-8);">
        <h2 class="zaq-text-heading" style="font-size: 1.125rem; margin: 0;">
          Which function should I use?
        </h2>
        <p
          class="zaq-text-caption"
          style="color: var(--zaq-text-color-body-secondary); margin: 0; line-height: 1.6;"
        >
          Module: <code style="font-family: var(--zaq-font-family-code, ui-monospace, monospace);">{@module}</code>.
          Styling tokens live in <code style="font-family: var(--zaq-font-family-code, ui-monospace, monospace);">modal.css</code>.
        </p>
      </div>
      <.decision_table />
      <nav
        class="zaq-text-caption"
        style="display: flex; flex-wrap: wrap; gap: var(--zaq-scale-12); color: var(--zaq-text-color-body-tertiary);"
      >
        <a href="#modal-shell" style="color: inherit;">modal_shell/1</a>
        <a href="#confirm-dialog" style="color: inherit;">confirm_dialog/1</a>
        <a href="#form-dialog" style="color: inherit;">form_dialog/1</a>
        <a href="#iframe-dialog" style="color: inherit;">iframe_dialog/1</a>
      </nav>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :when_to_use, :string, required: true
  attr :rows, :list, required: true
  attr :code, :string, required: true
  slot :inner_block, required: true

  defp doc_section(assigns) do
    ~H"""
    <section
      id={@id}
      style="display: flex; flex-direction: column; gap: var(--zaq-scale-20); scroll-margin-top: var(--zaq-scale-24);"
    >
      <div style="display: flex; flex-direction: column; gap: var(--zaq-scale-8);">
        <h2 class="zaq-text-heading" style="font-size: 1.125rem; margin: 0;">
          {@title}
        </h2>
        <p
          class="zaq-text-caption"
          style="color: var(--zaq-text-color-body-secondary); margin: 0; line-height: 1.6;"
        >
          {@when_to_use}
        </p>
      </div>

      <div style="display: flex; flex-direction: column; gap: var(--zaq-scale-8);">
        <h3 class="zaq-text-heading" style="font-size: 0.875rem; margin: 0;">
          Attributes
        </h3>
        <.attr_table rows={@rows} />
      </div>

      <div style="display: flex; flex-direction: column; gap: var(--zaq-scale-8);">
        <h3 class="zaq-text-heading" style="font-size: 0.875rem; margin: 0;">
          Usage
        </h3>
        <.usage_code code={@code} />
      </div>

      <div style="display: flex; flex-direction: column; gap: var(--zaq-scale-16);">
        <h3 class="zaq-text-heading" style="font-size: 0.875rem; margin: 0;">
          Previews
        </h3>
        {render_slot(@inner_block)}
      </div>
    </section>
    """
  end

  attr :rows, :list, required: true

  defp attr_table(assigns) do
    ~H"""
    <div style="overflow-x: auto; border: var(--zaq-border-thickness-default) solid var(--zaq-border-color-default); border-radius: var(--zaq-scale-12);">
      <table style="width: 100%; border-collapse: collapse; font-size: 0.8125rem; text-align: left;">
        <thead style="background: var(--zaq-surface-color-elevated);">
          <tr>
            <th style="padding: 0.625rem 0.75rem; font-weight: 600;">Attribute</th>
            <th style="padding: 0.625rem 0.75rem; font-weight: 600;">Type</th>
            <th style="padding: 0.625rem 0.75rem; font-weight: 600;">Default</th>
            <th style="padding: 0.625rem 0.75rem; font-weight: 600;">Notes</th>
          </tr>
        </thead>
        <tbody>
          <tr
            :for={row <- @rows}
            style="border-top: var(--zaq-border-thickness-default) solid var(--zaq-border-color-default);"
          >
            <td style="padding: 0.625rem 0.75rem; font-family: var(--zaq-font-family-code, ui-monospace, monospace); vertical-align: top;">
              {row.name}
            </td>
            <td style="padding: 0.625rem 0.75rem; vertical-align: top; color: var(--zaq-text-color-body-secondary);">
              {row.type}
            </td>
            <td style="padding: 0.625rem 0.75rem; vertical-align: top; color: var(--zaq-text-color-body-secondary);">
              {row.default}
            </td>
            <td style="padding: 0.625rem 0.75rem; vertical-align: top; line-height: 1.5;">
              {row.notes}
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  attr :code, :string, required: true

  defp usage_code(assigns) do
    ~H"""
    <pre style="margin: 0; padding: var(--zaq-scale-16); overflow-x: auto; border-radius: var(--zaq-scale-12); border: var(--zaq-border-thickness-default) solid var(--zaq-border-color-default); background: var(--zaq-surface-color-elevated); font-family: var(--zaq-font-family-code, ui-monospace, monospace); font-size: 0.75rem; line-height: 1.6;"><code>{@code}</code></pre>
    """
  end

  attr :label, :string, required: true
  attr :class, :string, default: ""
  slot :inner_block, required: true

  defp preview_frame(assigns) do
    ~H"""
    <div style="display: flex; flex-direction: column; gap: var(--zaq-scale-8);">
      <span
        class="zaq-text-caption"
        style="color: var(--zaq-text-color-body-tertiary); text-transform: uppercase; letter-spacing: 0.04em; font-size: 0.6875rem;"
      >
        {@label}
      </span>
      <div class={["zaq-modal-preview", @class]}>
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  defp decision_table(assigns) do
    ~H"""
    <div style="overflow-x: auto; border: var(--zaq-border-thickness-default) solid var(--zaq-border-color-default); border-radius: var(--zaq-scale-12);">
      <table style="width: 100%; border-collapse: collapse; font-size: 0.8125rem; text-align: left;">
        <thead style="background: var(--zaq-surface-color-elevated);">
          <tr>
            <th style="padding: 0.625rem 0.75rem; font-weight: 600;">Function</th>
            <th style="padding: 0.625rem 0.75rem; font-weight: 600;">Use when</th>
          </tr>
        </thead>
        <tbody>
          <tr style="border-top: var(--zaq-border-thickness-default) solid var(--zaq-border-color-default);">
            <td style="padding: 0.625rem 0.75rem; font-family: var(--zaq-font-family-code, ui-monospace, monospace);">
              modal_shell/1
            </td>
            <td style="padding: 0.625rem 0.75rem; line-height: 1.5;">
              Custom body layout (file preview, pickers). Pass `title` for shared header chrome; override `panel_base_class` for flush layouts.
            </td>
          </tr>
          <tr style="border-top: var(--zaq-border-thickness-default) solid var(--zaq-border-color-default);">
            <td style="padding: 0.625rem 0.75rem; font-family: var(--zaq-font-family-code, ui-monospace, monospace);">
              confirm_dialog/1
            </td>
            <td style="padding: 0.625rem 0.75rem; line-height: 1.5;">
              Delete / destructive action — trash icon, centered copy, red confirm button.
            </td>
          </tr>
          <tr style="border-top: var(--zaq-border-thickness-default) solid var(--zaq-border-color-default);">
            <td style="padding: 0.625rem 0.75rem; font-family: var(--zaq-font-family-code, ui-monospace, monospace);">
              form_dialog/1
            </td>
            <td style="padding: 0.625rem 0.75rem; line-height: 1.5;">
              Standard add/edit popin — DS shell, scrollable body with DesignSystem form controls, optional footer actions.
            </td>
          </tr>
          <tr style="border-top: var(--zaq-border-thickness-default) solid var(--zaq-border-color-default);">
            <td style="padding: 0.625rem 0.75rem; font-family: var(--zaq-font-family-code, ui-monospace, monospace);">
              iframe_dialog/1
            </td>
            <td style="padding: 0.625rem 0.75rem; line-height: 1.5;">
              Embedded external page (OAuth, third-party admin UI).
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  defp modal_shell_rows do
    [
      %{name: "id", type: "string", default: "nil", notes: "Root element id."},
      %{
        name: "cancel_event",
        type: "string",
        default: "—",
        notes: "Required. Backdrop + Escape event name."
      },
      %{
        name: "title",
        type: "string",
        default: "nil",
        notes: "Optional. Renders shared `.zaq-modal-header` + `.zaq-modal-body` wrapper."
      },
      %{
        name: "title_id",
        type: "string",
        default: "nil",
        notes: "Optional heading id; defaults to `{id}-title` when `id` is set."
      },
      %{
        name: "header_actions",
        type: "slot",
        default: "[]",
        notes: "Optional controls before the close button when `title` is set."
      },
      %{
        name: "max_width_class",
        type: "string",
        default: "zaq-modal--width-sm",
        notes: "Panel max-width preset from modal.css."
      },
      %{name: "panel_class", type: "string", default: "\"\"", notes: "Extra classes on panel."},
      %{
        name: "backdrop_class",
        type: "string",
        default: "zaq-bo-modal-backdrop",
        notes: "Scrim element class."
      },
      %{
        name: "panel_base_class",
        type: "string",
        default: "zaq-modal",
        notes: "Panel shell. Use zaq-modal zaq-modal--flush for edge-to-edge inner layout."
      },
      %{name: "inner_block", type: "slot", default: "—", notes: "Required. Modal body content."}
    ]
  end

  defp confirm_dialog_rows do
    [
      %{name: "id", type: "string", default: "nil", notes: "Passed to modal_shell."},
      %{
        name: "cancel_event",
        type: "string",
        default: "cancel_delete",
        notes: "Cancel button, backdrop, Escape."
      },
      %{
        name: "confirm_event",
        type: "string",
        default: "delete",
        notes: "Confirm button phx-click."
      },
      %{name: "title", type: "string", default: "—", notes: "Required. Dialog heading."},
      %{name: "message", type: "string", default: "—", notes: "Required. Supporting copy."},
      %{name: "confirm_label", type: "string", default: "Delete", notes: "Primary button label."},
      %{
        name: "cancel_label",
        type: "string",
        default: "Cancel",
        notes: "Secondary button label."
      },
      %{name: "max_width_class", type: "string", default: "max-w-sm", notes: "Panel width."},
      %{
        name: "confirm_button_id",
        type: "string",
        default: "nil",
        notes: "Optional id for E2E / targeted clicks."
      },
      %{
        name: "confirm_value_id",
        type: "string",
        default: "nil",
        notes: "Optional phx-value-id on confirm."
      }
    ]
  end

  defp form_dialog_rows do
    [
      %{
        name: "id",
        type: "string",
        default: "nil",
        notes: "Root id; also drives aria-labelledby."
      },
      %{
        name: "cancel_event",
        type: "string",
        default: "—",
        notes: "Required. Close button, backdrop, Escape."
      },
      %{name: "title", type: "string", default: "—", notes: "Required. Header title."},
      %{
        name: "max_width_class",
        type: "string",
        default: "zaq-modal--width-3xl",
        notes: "Panel max-width preset from modal.css (e.g. zaq-modal--width-lg)."
      },
      %{name: "panel_class", type: "string", default: "\"\"", notes: "Extra panel classes."},
      %{
        name: "body_class",
        type: "string",
        default: "\"\"",
        notes: "Extra classes on scroll body."
      },
      %{
        name: "inner_block",
        type: "slot",
        default: "—",
        notes: "Required. Form fields / content."
      },
      %{
        name: "actions",
        type: "slot",
        default: "[]",
        notes: "Optional footer — pass DesignSystem.Button components. Omitted when empty."
      }
    ]
  end

  defp iframe_dialog_rows do
    [
      %{name: "id", type: "string", default: "nil", notes: "Passed to modal_shell."},
      %{name: "cancel_event", type: "string", default: "—", notes: "Required."},
      %{name: "title", type: "string", default: "—", notes: "Required. Shown above iframe."},
      %{name: "src", type: "string", default: "—", notes: "Required. iframe URL."},
      %{
        name: "max_width_class",
        type: "string",
        default: "zaq-modal--width-4xl",
        notes: "Panel width (`modal.css` preset)."
      },
      %{
        name: "height_class",
        type: "string",
        default: "\"\"",
        notes: "Optional extra classes on iframe. Default height is 75vh via `.zaq-modal-iframe`."
      }
    ]
  end

  defp modal_shell_usage do
    """
    <.modal_shell id="my-modal" cancel_event="close_modal">
      <p>Custom content</p>
    </.modal_shell>

    <%!-- Titled picker / custom body — shared header chrome --%>
    <.modal_shell
      id="mcp-picker-modal"
      cancel_event="close_mcp_picker"
      title="Add MCP endpoint"
      max_width_class="zaq-modal--width-lg"
    >
      ...
    </.modal_shell>

    <%!-- Flush inner layout (file preview) --%>
    <.modal_shell
      cancel_event="close_modal"
      panel_base_class="zaq-modal zaq-modal--flush"
      max_width_class="zaq-modal--width-4xl"
    >
      ...
    </.modal_shell>
    """
    |> String.trim()
  end

  defp confirm_dialog_usage do
    """
    <.confirm_dialog
      id="delete-modal"
      title="Delete user?"
      message="This action is permanent."
      cancel_event="cancel_delete"
      confirm_event="delete"
      confirm_button_id="confirm-delete-btn"
    />
    """
    |> String.trim()
  end

  defp form_dialog_usage do
    """
    <.form_dialog
      id="edit-modal"
      cancel_event="cancel_edit"
      title="Edit item"
      max_width_class="zaq-modal--width-lg"
    >
      <.form for={@form} id="edit-item-form" class="zaq-layout-stack">
        <ZaqWeb.Components.DesignSystem.Input.input
          field={@form[:name]}
          label="Name"
        />
      </.form>
      <:actions>
        <ZaqWeb.Components.DesignSystem.Button.button
          variant={:secondary}
          phx-click="cancel_edit"
        >
          Cancel
        </ZaqWeb.Components.DesignSystem.Button.button>
        <ZaqWeb.Components.DesignSystem.Button.button
          variant={:primary}
          type="submit"
          form="edit-item-form"
        >
          Save
        </ZaqWeb.Components.DesignSystem.Button.button>
      </:actions>
    </.form_dialog>
    """
    |> String.trim()
  end

  defp iframe_dialog_usage do
    """
    <.iframe_dialog
      id="oauth-modal"
      cancel_event="close_oauth"
      title="Authorize application"
      src={@oauth_url}
    />
    """
    |> String.trim()
  end
end
