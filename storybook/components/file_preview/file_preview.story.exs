defmodule Storybook.Components.FilePreview.FilePreview do
  use PhoenixStorybook.Story, :page

  alias ZaqWeb.Storybook.FilePreviewFixtures, as: FP

  def description do
    """
    Inline `FilePreview.meta/1` and `FilePreview.panel/1` — same preview map shape as \
    `ZaqWeb.Live.BO.AI.FilePreviewData.load/2`. Each `panel/1` block sits on \
    `--zaq-surface-color-base` so the story tracks light/dark theme like the app scroll area. \
    Close / Escape on the real modal require LiveView (`cancel_event`).
    """
  end

  defp panel_preview_frame_style do
    Enum.join(
      [
        "background: var(--zaq-surface-color-base)",
        "padding: var(--zaq-scale-24)",
        "border-radius: var(--zaq-scale-16)",
        "border: var(--zaq-border-thickness-default) solid var(--zaq-border-color-default)"
      ],
      "; "
    ) <> ";"
  end

  def render(assigns) do
    ~H"""
    <div style="font-family: var(--zaq-font-primary, monospace); padding: 2rem; display: flex; flex-direction: column; gap: 3rem; max-width: 56rem;">
      <section>
        <h2 style="font-size: 0.7rem; font-weight: 600; letter-spacing: 0.1em; text-transform: uppercase; opacity: 0.45; margin-bottom: 0.5rem;">
          meta/1 — file metadata
        </h2>
        <p style="font-size: 0.75rem; opacity: 0.5; font-family: ui-monospace, monospace; margin-bottom: 1rem;">
          &lt;ZaqWeb.Components.FilePreview.meta preview=&#123;&#64;preview&#125; /&gt;
        </p>
        <div style="display: flex; justify-content: flex-end;">
          <ZaqWeb.Components.FilePreview.meta preview={FP.meta_only_preview()} />
        </div>
      </section>

      <section>
        <h2 style="font-size: 0.7rem; font-weight: 600; letter-spacing: 0.1em; text-transform: uppercase; opacity: 0.45; margin-bottom: 0.5rem;">
          panel/1 — markdown
        </h2>
        <p style="font-size: 0.75rem; opacity: 0.5; font-family: ui-monospace, monospace; margin-bottom: 1rem;">
          HTML from
          <code style="font-family: ui-monospace, monospace;">ZaqWeb.Helpers.Markdown.render/1</code>
          (same as ingestion).
        </p>
        <div style={panel_preview_frame_style()}>
          <ZaqWeb.Components.FilePreview.panel preview={FP.markdown()} />
        </div>
      </section>

      <section>
        <h2 style="font-size: 0.7rem; font-weight: 600; letter-spacing: 0.1em; text-transform: uppercase; opacity: 0.45; margin-bottom: 0.5rem;">
          panel/1 — text
        </h2>
        <div style={panel_preview_frame_style()}>
          <ZaqWeb.Components.FilePreview.panel preview={FP.text()} />
        </div>
      </section>

      <section>
        <h2 style="font-size: 0.7rem; font-weight: 600; letter-spacing: 0.1em; text-transform: uppercase; opacity: 0.45; margin-bottom: 0.5rem;">
          panel/1 — image
        </h2>
        <div style={panel_preview_frame_style()}>
          <ZaqWeb.Components.FilePreview.panel preview={FP.image()} />
        </div>
      </section>

      <section>
        <h2 style="font-size: 0.7rem; font-weight: 600; letter-spacing: 0.1em; text-transform: uppercase; opacity: 0.45; margin-bottom: 0.5rem;">
          panel/1 — pdf
        </h2>
        <p style="font-size: 0.75rem; opacity: 0.5; font-family: ui-monospace, monospace; margin-bottom: 1rem;">
          Default <code style="font-family: ui-monospace, monospace;">pdf_height</code>
          is <code style="font-family: ui-monospace, monospace;">80vh</code>
          on <code style="font-family: ui-monospace, monospace;">panel/1</code>; the modal passes <code style="font-family: ui-monospace, monospace;">68vh</code>.
        </p>
        <div style={panel_preview_frame_style()}>
          <ZaqWeb.Components.FilePreview.panel preview={FP.pdf()} pdf_height="min(40vh, 320px)" />
        </div>
      </section>

      <section>
        <h2 style="font-size: 0.7rem; font-weight: 600; letter-spacing: 0.1em; text-transform: uppercase; opacity: 0.45; margin-bottom: 0.5rem;">
          panel/1 — binary (download)
        </h2>
        <div style={panel_preview_frame_style()}>
          <ZaqWeb.Components.FilePreview.panel preview={FP.binary()} />
        </div>
      </section>

      <section>
        <h2 style="font-size: 0.7rem; font-weight: 600; letter-spacing: 0.1em; text-transform: uppercase; opacity: 0.45; margin-bottom: 0.5rem;">
          panel/1 — file not found
        </h2>
        <div style={panel_preview_frame_style()}>
          <ZaqWeb.Components.FilePreview.panel preview={FP.not_found()} />
        </div>
      </section>
    </div>
    """
  end
end
