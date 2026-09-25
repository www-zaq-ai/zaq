defmodule ZaqWeb.Components.DesignSystem.ChannelConnectorCardTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ZaqWeb.Components.DesignSystem.ChannelConnectorCard

  test "renders connector state and parent-owned actions without changing their events" do
    html =
      render_component(&ChannelConnectorCard.channel_connector_card/1,
        id: "config-card-12",
        name: "Shared inbox",
        provider: "IMAP",
        enabled: true,
        connector_id: 12,
        select_event: "select_config",
        selected: true,
        actions: [
          %{
            inner_block: fn _, _ ->
              Phoenix.HTML.raw(
                ~s(<button id="toggle-config-12" phx-click="toggle_enabled">Disable</button>)
              )
            end
          }
        ]
      )

    assert html =~ ~s(id="config-card-12")
    assert html =~ "Shared inbox"
    assert html =~ "Active"
    assert html =~ ~s(phx-click="select_config")
    assert html =~ ~s(phx-value-id="12")
    assert html =~ ~s(id="toggle-config-12" phx-click="toggle_enabled")
  end

  test "disabled connector without selection does not emit selection event" do
    html =
      render_component(&ChannelConnectorCard.channel_connector_card/1,
        id: "config-card-13",
        name: "Other inbox",
        provider: "IMAP"
      )

    assert html =~ "Disabled"
    refute html =~ "phx-click"
  end
end
