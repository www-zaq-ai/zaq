defmodule ZaqWeb.LayoutsTest do
  use ZaqWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

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

  test "theme_toggle/1 renders all theme buttons" do
    html = render_component(&Layouts.theme_toggle/1, %{})

    assert html =~ "data-phx-theme=\"system\""
    assert html =~ "data-phx-theme=\"light\""
    assert html =~ "data-phx-theme=\"dark\""
  end
end
