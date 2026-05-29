defmodule Storybook.Components.FilePreview.FilePreviewModal do
  use PhoenixStorybook.Story, :page

  def description, do: "Modal wrapper for file preview — includes header, metadata, raw file link, and close button."

  def render(assigns) do
    ~H"""
    <div style="font-family: var(--zaq-font-primary, monospace); padding: 2rem; max-width: 700px;">
      <p style="font-size: 0.75rem; opacity: 0.5; font-family: ui-monospace, monospace; margin-bottom: 1.5rem;">
        &lt;ZaqWeb.Components.FilePreviewModal.modal preview=&#123;&#64;preview&#125; cancel_event="close_preview_modal" /&gt;
      </p>
      <p style="font-size: 0.85rem; opacity: 0.6; line-height: 1.6;">
        This component renders a full modal overlay. In the app it is toggled via a LiveView event.
        Use <code style="font-family: ui-monospace, monospace;">cancel_event</code> to wire the close button to a <code style="font-family: ui-monospace, monospace;">phx-click</code> handler that sets the preview to nil.
      </p>
      <pre style="margin-top: 1.5rem; background: var(--zaq-color-surface, #faf9f7); border: 1px solid var(--zaq-color-surface-border, #e8e6e1); border-radius: 6px; padding: 1rem; font-size: 0.75rem; overflow-x: auto;"><code>&lt;ZaqWeb.Components.FilePreviewModal.modal
  id="file-preview-modal"
  preview=&#123;&#64;selected_preview&#125;
  cancel_event="close_preview_modal"
/&gt;</code></pre>

      <table style="width: 100%; margin-top: 2rem; font-size: 0.8rem; border-collapse: collapse;">
        <thead>
          <tr style="border-bottom: 1px solid var(--zaq-color-surface-border, #e8e6e1);">
            <th style="text-align: left; padding: 0.5rem 0.75rem; opacity: 0.5;">Attr</th>
            <th style="text-align: left; padding: 0.5rem 0.75rem; opacity: 0.5;">Type</th>
            <th style="text-align: left; padding: 0.5rem 0.75rem; opacity: 0.5;">Default</th>
            <th style="text-align: left; padding: 0.5rem 0.75rem; opacity: 0.5;">Notes</th>
          </tr>
        </thead>
        <tbody>
          <tr style="border-bottom: 1px solid var(--zaq-color-surface-border, #e8e6e1);">
            <td style="padding: 0.5rem 0.75rem; font-family: ui-monospace, monospace;">preview</td>
            <td style="padding: 0.5rem 0.75rem; opacity: 0.6;">map</td>
            <td style="padding: 0.5rem 0.75rem; opacity: 0.4;">required</td>
            <td style="padding: 0.5rem 0.75rem; opacity: 0.6;">Preview map from FilePreview context</td>
          </tr>
          <tr style="border-bottom: 1px solid var(--zaq-color-surface-border, #e8e6e1);">
            <td style="padding: 0.5rem 0.75rem; font-family: ui-monospace, monospace;">cancel_event</td>
            <td style="padding: 0.5rem 0.75rem; opacity: 0.6;">string</td>
            <td style="padding: 0.5rem 0.75rem; font-family: ui-monospace, monospace; opacity: 0.6;">"close_preview_modal"</td>
            <td style="padding: 0.5rem 0.75rem; opacity: 0.6;">phx-click event fired on close</td>
          </tr>
          <tr>
            <td style="padding: 0.5rem 0.75rem; font-family: ui-monospace, monospace;">id</td>
            <td style="padding: 0.5rem 0.75rem; opacity: 0.6;">string</td>
            <td style="padding: 0.5rem 0.75rem; font-family: ui-monospace, monospace; opacity: 0.6;">"file-preview-modal"</td>
            <td style="padding: 0.5rem 0.75rem; opacity: 0.6;">DOM id for JS targeting</td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end
end
