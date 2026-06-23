defmodule Storybook.Components.Cards.DiagnosticCard do
  use PhoenixStorybook.Story, :page
  use Phoenix.Component

  import ZaqWeb.Components.DesignSystem.DiagnosticCard

  def description,
    do:
      "Service connection card with a status badge and optional test button. The :event attribute triggers a phx-click LiveView event."

  def render(assigns) do
    ~H"""
    <div style="font-family: var(--zaq-font-primary, monospace); padding: 2rem; display: flex; flex-direction: column; gap: 2rem; max-width: 600px;">
      <p style="font-size: 0.75rem; opacity: 0.5; font-family: ui-monospace, monospace;">
        &lt;ZaqWeb.Components.DesignSystem.DiagnosticCard.diagnostic_card label="Database" status={:ok} event="test_db"&gt;...&lt;/&gt;
      </p>

      <div>
        <h3 style="font-size: 0.65rem; font-weight: 600; letter-spacing: 0.08em; text-transform: uppercase; opacity: 0.35; margin-bottom: 0.75rem;">
          States
        </h3>
        <div style="display: flex; gap: 1rem; flex-wrap: wrap;">
          <.demo label="idle">
            <.diagnostic_card label="Database" status={:idle} event="test_db">
              PostgreSQL connection
            </.diagnostic_card>
          </.demo>
          <.demo label="loading">
            <.diagnostic_card label="Vector store" status={:loading} event="test_vs">
              Pgvector connection
            </.diagnostic_card>
          </.demo>
          <.demo label="ok">
            <.diagnostic_card label="Mattermost" status={:ok} event="test_mm">
              Mattermost webhook
            </.diagnostic_card>
          </.demo>
          <.demo label="error">
            <.diagnostic_card label="SMTP" status={{:error, "Timeout"}} event="test_smtp">
              Email server
            </.diagnostic_card>
          </.demo>
        </div>
      </div>

      <div>
        <h3 style="font-size: 0.65rem; font-weight: 600; letter-spacing: 0.08em; text-transform: uppercase; opacity: 0.35; margin-bottom: 0.75rem;">
          Custom button label
        </h3>
        <.diagnostic_card
          label="LLM Provider"
          status={:ok}
          event="test_llm"
          button_label="Test API"
        >
          OpenAI API
        </.diagnostic_card>
      </div>
    </div>
    """
  end

  defp demo(assigns) do
    ~H"""
    <div style="display: flex; flex-direction: column; gap: 0.4rem;">
      <span style="font-size: 0.65rem; font-family: ui-monospace, monospace; opacity: 0.4;">
        {@label}
      </span>
      {render_slot(@inner_block)}
    </div>
    """
  end
end
