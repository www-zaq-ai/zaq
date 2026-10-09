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

  test "common controls preserve parent-owned IDs, events and edit action" do
    html =
      render_component(&ChannelConnectorCard.channel_connector_card/1,
        id: "config-card-12",
        name: "Shared inbox",
        provider: "IMAP",
        enabled: true,
        connector_id: 12,
        toggle_event: "toggle_enabled",
        toggle_button_id: "toggle-config-12",
        edit_event: "open_modal",
        edit_button_id: "edit-config-12",
        edit_action: "edit"
      )

    document = LazyHTML.from_fragment(html)
    toggle = LazyHTML.query(document, "#toggle-config-12")
    edit = LazyHTML.query(document, "#edit-config-12")
    assert String.trim(LazyHTML.text(toggle)) == "Disable"
    assert LazyHTML.attribute(toggle, "phx-click") == ["toggle_enabled"]
    assert LazyHTML.attribute(toggle, "phx-value-id") == ["12"]
    assert LazyHTML.attribute(toggle, "class") |> hd() =~ "zaq-btn-secondary"
    assert LazyHTML.attribute(edit, "phx-click") == ["open_modal"]
    assert LazyHTML.attribute(edit, "phx-value-id") == ["12"]
    assert LazyHTML.attribute(edit, "phx-value-action") == ["edit"]
    assert LazyHTML.attribute(edit, "aria-label") == ["Edit"]
    refute Enum.empty?(LazyHTML.query(edit, ".hero-pencil-square"))
  end

  test "common controls reflect enabled and prerequisite states without coupling edit to toggle" do
    for enabled <- [false, true], disabled <- [false, true] do
      html =
        render_component(&ChannelConnectorCard.channel_connector_card/1,
          id: "widget-12",
          name: "Widget",
          provider: "Web Widget",
          connector_id: 12,
          enabled: enabled,
          toggle_event: "toggle_enabled",
          toggle_disabled: disabled,
          toggle_disabled_reason: "Configure the adapter before enabling.",
          edit_event: "select_connector"
        )

      document = LazyHTML.from_fragment(html)
      toggle = LazyHTML.query(document, "#toggle-widget-12")
      edit = LazyHTML.query(document, "#edit-widget-12")
      assert String.trim(LazyHTML.text(toggle)) == if(enabled, do: "Disable", else: "Enable")
      assert LazyHTML.attribute(toggle, "disabled") != [] == disabled
      assert LazyHTML.attribute(toggle, "title") == ["Configure the adapter before enabling."]
      assert LazyHTML.attribute(edit, "disabled") == []
      assert LazyHTML.attribute(edit, "phx-value-action") == []
    end
  end

  test "edit and toggle are independently optional" do
    for {event, selector} <- [{:edit_event, "#edit-card-12"}, {:toggle_event, "#toggle-card-12"}] do
      html =
        render_component(
          &ChannelConnectorCard.channel_connector_card/1,
          [id: "card-12", name: "Widget", provider: "Web Widget", connector_id: 12] ++
            [{event, "manage"}]
        )

      document = LazyHTML.from_fragment(html)
      assert Enum.count(LazyHTML.query(document, "button")) == 1
      refute Enum.empty?(LazyHTML.query(document, selector))
    end
  end
end
