defmodule Storybook.Modals.BoModal do
  use PhoenixStorybook.Story, :page
  use Phoenix.Component

  import ZaqWeb.Components.BOModal

  @cancel_event "storybook_close_modal"
  @module "ZaqWeb.Components.BOModal"

  def description do
    """
    Back-office modal primitives (`#{@module}`). Scroll this page for a decision guide, attribute reference, usage snippets, and bounded previews for each function.
    """
    |> String.trim()
  end

  def render(assigns) do
    assigns = assign(assigns, :cancel_event, @cancel_event)

    ~H"""
    <div
      class="zaq-text-body zaq-sandbox"
      style="padding: var(--zaq-scale-32); max-width: 52rem; display: flex; flex-direction: column; gap: var(--zaq-scale-48);"
    >
      <.intro_section />
      <.doc_section
        id="modal-shell"
        title="modal_shell/1"
        when_to_use="Low-level wrapper for custom modal bodies. Uses `modal.css` tokens (`zaq-bo-modal-backdrop`, `zaq-modal`). Prefer `form_dialog/1` for standard add/edit popins."
        rows={modal_shell_rows()}
        code={modal_shell_usage()}
      >
        <.preview_frame label="Default — centered panel (`max-w-sm`)">
          <.modal_shell id="sb-shell-default" cancel_event={@cancel_event}>
            <p class="font-mono text-[0.75rem] text-black/65 text-center">
              Pass any markup in the inner block.
            </p>
          </.modal_shell>
        </.preview_frame>
        <.preview_frame label="Flush panel — zaq-modal--flush on panel_base_class">
          <.modal_shell
            id="sb-shell-flush"
            cancel_event={@cancel_event}
            max_width_class="max-w-md"
            panel_base_class="zaq-modal zaq-modal--flush"
          >
            <div class="border-b border-black/[0.08] px-4 py-3 font-mono text-[0.75rem] font-bold">
              Toolbar
            </div>
            <div class="p-4 font-mono text-[0.75rem] text-black/65">
              Edge-to-edge content (file preview, tables).
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
        when_to_use="Default for BO add/edit dialogs. Header, scrollable body (`max-h-[90vh]`), optional `:actions` slot. Own backdrop — does not use `modal_shell/1`."
        rows={form_dialog_rows()}
        code={form_dialog_usage()}
      >
        <.preview_frame label="With `:actions` slot" class="zaq-modal-preview--tall">
          <.form_dialog
            id="sb-form-actions"
            cancel_event={@cancel_event}
            title="Edit workspace"
            max_width_class="max-w-lg"
          >
            <p class="font-mono text-[0.75rem] text-black/65">
              Body scrolls when content exceeds the viewport. Footer actions stay pinned.
            </p>
            <:actions>
              <button
                type="button"
                phx-click={@cancel_event}
                class="rounded-xl border border-black/10 px-5 py-2.5 font-mono text-[0.75rem] text-black/40"
              >
                Cancel
              </button>
              <button
                type="button"
                class="rounded-xl bg-black px-5 py-2.5 font-mono text-[0.75rem] font-bold text-white"
              >
                Save
              </button>
            </:actions>
          </.form_dialog>
        </.preview_frame>
        <.preview_frame label="Body only — omit `:actions` when the form owns its footer">
          <.form_dialog
            id="sb-form-body-only"
            cancel_event={@cancel_event}
            title="Rename folder"
            max_width_class="max-w-sm"
          >
            <label class="block font-mono text-[0.75rem] text-black/65">
              Name
              <input
                type="text"
                value="Q1 reports"
                class="mt-2 w-full rounded-lg border border-black/10 px-3 py-2 font-mono text-[0.75rem]"
              />
            </label>
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
            src="about:blank"
            max_width_class="max-w-3xl"
            height_class="h-48"
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
              Custom body layout (file preview, one-off panels). Override `panel_base_class` for flush chrome.
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
              Standard add/edit popin — titled header, scrollable body, optional footer actions.
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
        name: "max_width_class",
        type: "string",
        default: "max-w-sm",
        notes: "Tailwind max-width on panel."
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
      %{name: "max_width_class", type: "string", default: "max-w-3xl", notes: "Panel max width."},
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
        notes: "Optional footer buttons. Omitted when empty."
      }
    ]
  end

  defp iframe_dialog_rows do
    [
      %{name: "id", type: "string", default: "nil", notes: "Passed to modal_shell."},
      %{name: "cancel_event", type: "string", default: "—", notes: "Required."},
      %{name: "title", type: "string", default: "—", notes: "Required. Shown above iframe."},
      %{name: "src", type: "string", default: "—", notes: "Required. iframe URL."},
      %{name: "max_width_class", type: "string", default: "max-w-4xl", notes: "Panel width."},
      %{name: "height_class", type: "string", default: "h-[75vh]", notes: "iframe height class."}
    ]
  end

  defp modal_shell_usage do
    """
    <.modal_shell id="my-modal" cancel_event="close_modal">
      <p>Custom content</p>
    </.modal_shell>

    <%!-- Flush inner layout (file preview) --%>
    <.modal_shell
      cancel_event="close_modal"
      panel_base_class="zaq-modal zaq-modal--flush"
      max_width_class="max-w-4xl"
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
    <.form_dialog id="edit-modal" cancel_event="cancel_edit" title="Edit item">
      <.input ... />
      <:actions>
        <.button variant={:secondary} phx-click="cancel_edit">Cancel</.button>
        <.button variant={:primary} type="submit">Save</.button>
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
      height_class="h-[60vh]"
    />
    """
    |> String.trim()
  end
end
