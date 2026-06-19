defmodule Storybook.Components.Misc.ConfigRow do
  use PhoenixStorybook.Story, :page

  def description,
    do:
      "Label / value display row. Optional :hint renders an inline tooltip. :truncate clips long values."

  def render(assigns) do
    ~H"""
    <div style="font-family: var(--zaq-font-primary, monospace); padding: 2rem; display: flex; flex-direction: column; gap: 2rem; max-width: 600px;">
      <p style="font-size: 0.75rem; opacity: 0.5; font-family: ui-monospace, monospace;">
        &lt;ZaqWeb.Components.BOLayout.config_row label="Model" value="claude-opus-4-7" hint="..." /&gt;
      </p>

      <div>
        <h3 style="font-size: 0.65rem; font-weight: 600; letter-spacing: 0.08em; text-transform: uppercase; opacity: 0.35; margin-bottom: 0.75rem;">
          Basic
        </h3>
        <div style="border: 1px solid var(--zaq-color-surface-border, #e8e6e1); border-radius: 6px; overflow: hidden;">
          <ZaqWeb.Components.BOLayout.config_row
            label="API Endpoint"
            value="https://api.example.com/v2"
          />
          <ZaqWeb.Components.BOLayout.config_row label="Region" value="eu-west-1" />
        </div>
      </div>

      <div>
        <h3 style="font-size: 0.65rem; font-weight: 600; letter-spacing: 0.08em; text-transform: uppercase; opacity: 0.35; margin-bottom: 0.75rem;">
          With hint
        </h3>
        <div style="border: 1px solid var(--zaq-color-surface-border, #e8e6e1); border-radius: 6px; overflow: hidden;">
          <ZaqWeb.Components.BOLayout.config_row
            label="Model"
            value="claude-opus-4-7"
            hint="The default LLM used by all agents."
          />
          <ZaqWeb.Components.BOLayout.config_row
            label="Embedding model"
            value="text-embedding-3-small"
            hint="Used for document chunking and retrieval."
          />
        </div>
      </div>

      <div>
        <h3 style="font-size: 0.65rem; font-weight: 600; letter-spacing: 0.08em; text-transform: uppercase; opacity: 0.35; margin-bottom: 0.75rem;">
          Truncated (long value)
        </h3>
        <div style="border: 1px solid var(--zaq-color-surface-border, #e8e6e1); border-radius: 6px; overflow: hidden;">
          <ZaqWeb.Components.BOLayout.config_row
            label="API Key"
            value="sk-live-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
            truncate={true}
          />
        </div>
      </div>
    </div>
    """
  end
end
