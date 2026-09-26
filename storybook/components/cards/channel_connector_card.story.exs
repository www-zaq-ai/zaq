defmodule Storybook.Components.Cards.ChannelConnectorCard do
  use PhoenixStorybook.Story, :page
  use Phoenix.Component

  import ZaqWeb.Components.DesignSystem.ChannelConnectorCard

  def description,
    do: "Connector settings bar with parent-owned selection, status, and action buttons."

  def render(assigns) do
    ~H"""
    <div class="space-y-4 p-6">
      <.channel_connector_card
        id="config-card-100"
        name="Workplace Mattermost"
        provider="Mattermost"
        url="https://chat.example.test"
        enabled
      >
        <:status><span class="status status-success" title="Ingress connected" /></:status>
        <:actions>
          <button id="toggle-config-100" class="zaq-btn zaq-btn-tertiary">Disable</button>
          <button id="edit-config-100" class="zaq-btn zaq-btn-tertiary">Edit</button>
        </:actions>
      </.channel_connector_card>

      <.channel_connector_card
        id="config-card-101"
        name="Shared IMAP inbox"
        provider="IMAP"
        url="imap.example.test"
        connector_id={101}
        select_event="select_config"
        selected
      >
        <:actions><button class="zaq-btn zaq-btn-tertiary">Configure</button></:actions>
      </.channel_connector_card>

      <.channel_connector_card
        id="config-card-102"
        name="Old SMTP account"
        provider="SMTP"
        connector_id={102}
        select_event="select_config"
      />
    </div>
    """
  end
end
