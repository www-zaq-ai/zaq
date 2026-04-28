defmodule ZaqWeb.Components.MCPEndpointIconsTest do
  use ZaqWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ZaqWeb.Components.MCPEndpointIcons

  test "renders dedicated icons for known predefined endpoint keys" do
    github =
      render_component(&MCPEndpointIcons.icon/1, endpoint_key: "github_mcp", class: "w-4 h-4")

    assert github =~ "#111827"

    stripe =
      render_component(&MCPEndpointIcons.icon/1, endpoint_key: "stripe_mcp", class: "w-4 h-4")

    assert stripe =~ "#635BFF"

    datagouv =
      render_component(&MCPEndpointIcons.icon/1, endpoint_key: "datagouv_mcp", class: "w-4 h-4")

    assert datagouv =~ "#1D4ED8"

    context_awesome =
      render_component(&MCPEndpointIcons.icon/1,
        endpoint_key: "context_awesome_mcp",
        class: "w-4 h-4"
      )

    assert context_awesome =~ "#FC60A8"

    tweetsave =
      render_component(&MCPEndpointIcons.icon/1, endpoint_key: "tweetsave_mcp", class: "w-4 h-4")

    assert tweetsave =~ "#38BDF8"
  end

  test "renders fallback icon for unknown or nil key" do
    unknown =
      render_component(&MCPEndpointIcons.icon/1, endpoint_key: "unknown", class: "w-5 h-5")

    assert unknown =~ "#E5E7EB"
    assert unknown =~ "#6B7280"

    nil_key = render_component(&MCPEndpointIcons.icon/1, class: "w-5 h-5")

    assert nil_key =~ "#E5E7EB"
    assert nil_key =~ "#6B7280"
  end
end
