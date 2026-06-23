defmodule Storybook.Dashboard.AIDiagnostics do
  use PhoenixStorybook.Story, :page
  use Phoenix.Component

  import ZaqWeb.Components.DesignSystem.DiagnosticCard

  def description,
    do:
      "BO AI Diagnostics page slice (`/bo/ai-diagnostics`) — service cards with connection tests. " <>
      "Card rows use `ZaqWeb.Components.BOLayout.config_row/1`: label/value pairs with optional `:hint` tooltip and `:truncate` for long values."

  def render(assigns) do
    ~H"""
    <div class="zaq-text-body" style="padding: var(--zaq-scale-32); max-width: 1200px;">
      <p
        class="zaq-text-caption"
        style="color: var(--zaq-text-color-body-tertiary); margin-bottom: var(--zaq-scale-24);"
      >
        Diagnostic cards grid — matches the live page. Rows are
        <code>&lt;ZaqWeb.Components.BOLayout.config_row /&gt;</code>
        inside <code>&lt;.diagnostic_card&gt;</code>.
      </p>

      <div class="grid grid-cols-3 gap-6">
        <.diagnostic_card label="LLM" status={:ok} event="test_llm">
          <ZaqWeb.Components.BOLayout.config_row
            label="Endpoint"
            value="https://api.openai.com/v1/chat/completions"
            truncate
            hint="System Config → LLM"
          />
          <ZaqWeb.Components.BOLayout.config_row
            label="Model"
            value="claude-opus-4-7"
            hint="System Config → LLM"
          />
          <ZaqWeb.Components.BOLayout.config_row
            label="Temperature"
            value="0.7"
            hint="System Config → LLM"
          />
          <ZaqWeb.Components.BOLayout.config_row
            label="Top-p"
            value="1.0"
            hint="System Config → LLM"
          />
          <ZaqWeb.Components.BOLayout.config_row
            label="Logprobs"
            value="no"
            hint="System Config → LLM"
          />
          <ZaqWeb.Components.BOLayout.config_row
            label="JSON Mode"
            value="yes"
            hint="System Config → LLM"
          />
          <ZaqWeb.Components.BOLayout.config_row
            label="Max Context"
            value="128000 tokens"
            hint="System Config → LLM"
          />
          <ZaqWeb.Components.BOLayout.config_row
            label="Distance Threshold"
            value="0.85"
            hint="System Config → LLM"
          />
        </.diagnostic_card>

        <.diagnostic_card label="Embedding" status={:idle} event="test_embedding">
          <ZaqWeb.Components.BOLayout.config_row
            label="Endpoint"
            value="https://api.openai.com/v1/embeddings"
            truncate
            hint="System Config → Embedding"
          />
          <ZaqWeb.Components.BOLayout.config_row
            label="Model"
            value="text-embedding-3-small"
            hint="System Config → Embedding"
          />
          <ZaqWeb.Components.BOLayout.config_row
            label="Dimension"
            value="1536"
            hint="System Config → Embedding"
          />
          <ZaqWeb.Components.BOLayout.config_row
            label="Chunk Min Tokens"
            value="64"
            hint="System Config → Embedding"
          />
          <ZaqWeb.Components.BOLayout.config_row
            label="Chunk Max Tokens"
            value="512"
            hint="System Config → Embedding"
          />
        </.diagnostic_card>

        <.diagnostic_card label="Image to Text" status={:ok} event="test_image_to_text">
          <ZaqWeb.Components.BOLayout.config_row
            label="Endpoint"
            value="https://api.openai.com/v1/chat/completions"
            truncate
            hint="System Config → Image to Text"
          />
          <ZaqWeb.Components.BOLayout.config_row
            label="Model"
            value="gpt-4o"
            hint="System Config → Image to Text"
          />
          <ZaqWeb.Components.BOLayout.config_row
            label="API Key"
            value="configured"
            hint="System Config → Image to Text"
          />
          <ZaqWeb.Components.BOLayout.config_row
            label="PDF Python"
            value="available"
            hint="mix zaq.python.fetch"
          />
        </.diagnostic_card>
      </div>
    </div>
    """
  end
end
