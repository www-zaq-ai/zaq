defmodule Storybook.Components.FilePreview.FilePreview do
  use PhoenixStorybook.Story, :page

  def description, do: "Inline file preview panel (PDF, image, text, markdown, binary, not found) and file metadata display."

  def render(assigns) do
    ~H"""
    <div style="font-family: var(--zaq-font-primary, monospace); padding: 2rem; display: flex; flex-direction: column; gap: 3rem; max-width: 700px;">

      <section>
        <h2 style="font-size: 0.7rem; font-weight: 600; letter-spacing: 0.1em; text-transform: uppercase; opacity: 0.45; margin-bottom: 0.5rem;">meta/1 — file metadata</h2>
        <p style="font-size: 0.75rem; opacity: 0.5; font-family: ui-monospace, monospace; margin-bottom: 1rem;">
          &lt;ZaqWeb.Components.FilePreview.meta preview=&#123;&#64;preview&#125; /&gt;
        </p>
        <ZaqWeb.Components.FilePreview.meta preview={%{
          file_size: 24_576,
          modified_at: NaiveDateTime.from_iso8601!("2024-03-15 09:22:00")
        }} />
      </section>

      <section>
        <h2 style="font-size: 0.7rem; font-weight: 600; letter-spacing: 0.1em; text-transform: uppercase; opacity: 0.45; margin-bottom: 0.5rem;">panel/1 — text file</h2>
        <p style="font-size: 0.75rem; opacity: 0.5; font-family: ui-monospace, monospace; margin-bottom: 1rem;">
          &lt;ZaqWeb.Components.FilePreview.panel preview=&#123;&#64;preview&#125; /&gt;
        </p>
        <div style="border: 1px solid var(--zaq-color-surface-border, #e8e6e1); border-radius: 8px; overflow: hidden; max-height: 200px;">
          <ZaqWeb.Components.FilePreview.panel preview={%{
            kind: :text,
            content: "# Onboarding Guide\n\nWelcome to ZAQ. This guide covers the first steps for new team members.\n\n## Step 1: Account setup\n\nYour IT team will provide your initial credentials.",
            ext: ".txt",
            file_size: 1_024,
            modified_at: NaiveDateTime.from_iso8601!("2024-03-10 14:00:00")
          }} />
        </div>
      </section>

      <section>
        <h2 style="font-size: 0.7rem; font-weight: 600; letter-spacing: 0.1em; text-transform: uppercase; opacity: 0.45; margin-bottom: 0.5rem;">panel/1 — file not found</h2>
        <div style="border: 1px solid var(--zaq-color-surface-border, #e8e6e1); border-radius: 8px; overflow: hidden;">
          <ZaqWeb.Components.FilePreview.panel preview={%{kind: :not_found, relative_path: "documents/missing-file.pdf"}} />
        </div>
      </section>

    </div>
    """
  end
end
