defmodule ZaqWeb.Components.DesignSystem.BreadcrumbTest do
  use ZaqWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ZaqWeb.Components.DesignSystem.Breadcrumb

  test "breadcrumb/1 is hidden at root with an empty trail" do
    html =
      render_component(&Breadcrumb.breadcrumb/1,
        current_dir: ".",
        breadcrumbs: []
      )

    refute html =~ "zaq-breadcrumb-row"
    refute html =~ "root"
  end

  test "breadcrumb/1 shows root and trail when inside a folder" do
    html =
      render_component(&Breadcrumb.breadcrumb/1,
        current_dir: "docs/sub",
        breadcrumbs: [
          %{name: "docs", path: "docs"},
          %{name: "sub", path: "docs/sub"}
        ]
      )

    assert html =~ "zaq-breadcrumb-row"
    assert html =~ "root"
    assert html =~ "docs"
    assert html =~ "sub"
    assert html =~ "zaq-breadcrumb-back-btn"
  end
end
