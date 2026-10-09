defmodule Storybook.Components.Cards.ChannelConnectorCard do
  use PhoenixStorybook.Story, :page
  use Phoenix.Component

  import ZaqWeb.Components.DesignSystem.ChannelConnectorCard

  def description,
    do: "Connector settings bar with shared edit/enable controls and provider-specific actions."

  def render(assigns) do
    ~H"""
    <div class="space-y-4 p-6">
      <.channel_connector_card
        id="config-card-100"
        name="Workplace Mattermost"
        provider="Mattermost"
        url="https://chat.example.test"
        enabled
        connector_id={100}
        toggle_event="toggle_enabled"
        toggle_button_id="toggle-config-100"
        edit_event="open_modal"
        edit_button_id="edit-config-100"
        edit_action="edit"
      >
        <:status><span class="status status-success" title="Ingress connected" /></:status>
      </.channel_connector_card>

      <.channel_connector_card
        id="config-card-101"
        name="Shared IMAP inbox"
        provider="IMAP"
        url="imap.example.test"
        connector_id={101}
        select_event="select_config"
        selected
        toggle_event="toggle_enabled"
        edit_event="select_config"
      >
      </.channel_connector_card>

      <.channel_connector_card
        id="config-card-102"
        name="Old SMTP account"
        provider="SMTP"
        connector_id={102}
        select_event="select_config"
      />
      <.channel_connector_card
        id="config-card-103"
        name="Website support"
        provider="Web Widget"
        url="Widget ID: 103"
        icon="hero-globe-alt"
        connector_id={103}
        toggle_event="toggle_enabled"
        toggle_disabled
        toggle_disabled_reason="Configure the global base URL and adapter before enabling."
        edit_event="select_connector"
      >
        <:actions>
          <ZaqWeb.Components.DesignSystem.Button.button variant={:secondary}>
            Installation script
          </ZaqWeb.Components.DesignSystem.Button.button>
        </:actions>
      </.channel_connector_card>
      <.channel_connector_card
        id="config-card-104"
        name="Enabled widget — readiness unverified"
        provider="Web Widget"
        url="Widget ID: 104"
        enabled
        enabled_label="Enabled"
        icon="hero-globe-alt"
        connector_id={104}
        toggle_event="toggle_enabled"
        edit_event="select_connector"
      >
        <:status>
          <ZaqWeb.Components.DesignSystem.Table.table_badge
            status="Unknown"
            tone={:neutral}
            title="Adapter does not support readiness checks"
          >Unknown</ZaqWeb.Components.DesignSystem.Table.table_badge>
        </:status>
      </.channel_connector_card>
    </div>
    """
  end
end
