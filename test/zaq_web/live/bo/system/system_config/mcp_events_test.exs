defmodule ZaqWeb.Live.BO.System.SystemConfig.MCPEventsTest do
  use ExUnit.Case, async: true

  alias Phoenix.LiveView.Socket
  alias ZaqWeb.Live.BO.System.SystemConfig.MCPEvents

  test "apply_filters/2 updates filters and resets page" do
    socket = %Socket{assigns: %{__changed__: %{}, mcp_page: 4}}

    updated =
      MCPEvents.apply_filters(socket, %{
        "mcp_filter_name" => "abc",
        "mcp_filter_type" => "remote",
        "mcp_filter_status" => "enabled"
      })

    assert updated.assigns.mcp_filter_name == "abc"
    assert updated.assigns.mcp_filter_type == "remote"
    assert updated.assigns.mcp_filter_status == "enabled"
    assert updated.assigns.mcp_page == 1
  end

  test "change_page/2 parses page with fallback" do
    socket = %Socket{assigns: %{__changed__: %{}, mcp_page: 3}}

    assert MCPEvents.change_page(socket, "9").assigns.mcp_page == 9
    assert MCPEvents.change_page(socket, "bad").assigns.mcp_page == 3
  end

  test "close/open/cancel delete modal helpers" do
    socket = %Socket{
      assigns: %{
        __changed__: %{},
        mcp_endpoint_modal: true,
        mcp_endpoint_delete_confirm_modal: false
      }
    }

    assert MCPEvents.open_delete_confirm(socket).assigns.mcp_endpoint_delete_confirm_modal
    refute MCPEvents.cancel_delete_confirm(socket).assigns.mcp_endpoint_delete_confirm_modal

    closed = MCPEvents.close_endpoint_modal(socket)
    refute closed.assigns.mcp_endpoint_modal
    refute closed.assigns.mcp_endpoint_delete_confirm_modal
  end
end
