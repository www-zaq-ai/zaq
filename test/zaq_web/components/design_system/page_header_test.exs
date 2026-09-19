defmodule ZaqWeb.Components.DesignSystem.PageHeaderTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ZaqWeb.Components.DesignSystem.{PageHeader, PersonHeader}

  test "shared heading preserves title, subtitle and tag contracts" do
    html =
      render_component(&PageHeader.page_heading/1,
        id: "sample",
        title: "Profile",
        description: "About you",
        tag: [%{inner_block: fn _, _ -> "Read-only" end}]
      )

    assert html =~ "id=\"sample-title\""
    assert html =~ "About you"
    assert html =~ "Read-only"
    assert html =~ "zaq-text-body"
  end

  test "custom subtitle takes precedence and empty heading uses larger text" do
    html =
      render_component(&PageHeader.page_heading/1,
        title: "Profile",
        description: "Fallback",
        subtitle: [%{inner_block: fn _, _ -> "Custom subtitle" end}]
      )

    assert html =~ "Custom subtitle"
    refute html =~ "Fallback"
    assert render_component(&PageHeader.page_heading/1, title: "Profile") =~ "zaq-text-body-lg"
  end

  test "People header nests mobile-aware theme controls in Settings and keeps People destinations" do
    html =
      render_component(&PersonHeader.person_header/1, title: "Profile", description: "About you")

    assert html =~ "/images/zaq.png"
    assert html =~ "alt=\"ZAQ\""
    assert html =~ "Appearance"
    refute html =~ "No personal settings available yet."
    assert html =~ "zaq-card-hover zaq-border-default zaq-header-menu-panel"
    assert html =~ "zaq-layout-inline relative"
    refute html =~ "id=\"people-settings-menu\" class=\"relative\""
    assert html =~ "/people/profile"
    assert html =~ "action=\"/people/session\""
    assert html =~ "value=\"delete\""
    assert html =~ "aria-label=\"Use dark theme\""
    assert html =~ "aria-label=\"Use light theme\""
    assert html =~ "aria-label=\"Use system theme\""
    assert html =~ "hidden sm:block"
    assert html =~ "flex-nowrap gap-2 sm:flex-wrap sm:gap-4"
    refute html =~ "/bo/"
    refute html =~ "bo-sidebar"
  end
end
