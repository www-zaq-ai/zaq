defmodule ZaqWeb.LayoutsTest do
  use ZaqWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ZaqWeb.Components.FigmaCaptureScript
  alias ZaqWeb.Layouts

  test "app/1 renders shell and inner content" do
    html =
      render_component(&Layouts.app/1,
        flash: %{},
        inner_block: [%{inner_block: fn _, _ -> "App Body" end}]
      )

    assert html =~ "App Body"
    assert html =~ "/images/logo.svg"
    assert html =~ "Get Started"
    assert html =~ "id=\"flash-group\""
  end

  test "flash_group/1 renders standard flash containers" do
    html = render_component(&Layouts.flash_group/1, flash: %{})

    assert html =~ "id=\"flash-group\""
    assert html =~ "id=\"client-error\""
    assert html =~ "id=\"server-error\""
  end

  test "figma_capture_script/1 renders script when enabled" do
    html = render_component(&FigmaCaptureScript.figma_capture_script/1, enabled: true)

    assert html =~ "https://mcp.figma.com/mcp/html-to-design/capture.js"
    assert html =~ "async"
  end

  test "figma_capture_script/1 does not render script when disabled" do
    html = render_component(&FigmaCaptureScript.figma_capture_script/1, enabled: false)

    refute html =~ "https://mcp.figma.com/mcp/html-to-design/capture.js"
  end
end
