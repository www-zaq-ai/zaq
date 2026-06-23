defmodule ZaqWeb.Components.DesignSystem.LinkTest do
  use ZaqWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ZaqWeb.Components.DesignSystem.Link

  test "nav_link/1 uses destination as navigate by default" do
    html =
      render_component(&Link.nav_link/1,
        destination: "/bo/ingestion",
        inner_block: [%{inner_block: fn _, _ -> "Browse" end}]
      )

    assert html =~ "zaq-link"
    assert html =~ "zaq-link-underline"
    assert html =~ "zaq-text-body"
    assert html =~ ~s(data-phx-link="redirect")
    assert html =~ "/bo/ingestion"
    assert html =~ "Browse"
  end

  test "nav_link/1 external uses destination as href" do
    html =
      render_component(&Link.nav_link/1,
        external: true,
        destination: "/bo/system-config?tab=embedding",
        inner_block: [%{inner_block: fn _, _ -> "Go to Settings →" end}]
      )

    assert html =~ ~s(href="/bo/system-config?tab=embedding")
    assert html =~ "Go to Settings →"
  end

  test "nav_link/1 tone default does not add accent shell class" do
    html =
      render_component(&Link.nav_link/1,
        destination: "/bo/ingestion",
        inner_block: [%{inner_block: fn _, _ -> "Browse" end}]
      )

    refute html =~ "zaq-link--accent"
  end

  test "nav_link/1 tone accent adds accent shell class" do
    html =
      render_component(&Link.nav_link/1,
        tone: :accent,
        destination: "/bo/ingestion",
        inner_block: [%{inner_block: fn _, _ -> "root" end}]
      )

    assert html =~ "zaq-link--accent"
    refute html =~ "zaq-link__label--accent"
    assert html =~ "root"
  end

  test "nav_link/1 with icon keeps underline on label only" do
    html =
      render_component(&Link.nav_link/1,
        destination: "/bo/dashboard",
        icon: "hero-arrow-right",
        icon_position: :left,
        inner_block: [%{inner_block: fn _, _ -> "Dashboard" end}]
      )

    assert html =~ "zaq-link__icon"
    assert html =~ "hero-arrow-right"
    assert html =~ "zaq-link-underline"
    refute html =~ ~s(class="zaq-link__icon zaq-link-underline")
    assert icon_before_label?(html)
  end

  test "nav_link/1 icon_position right renders icon after label" do
    html =
      render_component(&Link.nav_link/1,
        destination: "/bo/dashboard",
        icon: "hero-arrow-right",
        icon_position: :right,
        inner_block: [%{inner_block: fn _, _ -> "Dashboard" end}]
      )

    assert html =~ "zaq-link__icon"
    refute icon_before_label?(html)
  end

  test "nav_link/1 :sm applies body-sm typography" do
    html =
      render_component(&Link.nav_link/1,
        size: :sm,
        destination: "/bo/dashboard",
        inner_block: [%{inner_block: fn _, _ -> "Small link" end}]
      )

    assert html =~ "zaq-text-body-sm"
  end

  test "nav_link/1 merges optional class attribute" do
    html =
      render_component(&Link.nav_link/1,
        class: "mt-2",
        destination: "/bo/dashboard",
        inner_block: [%{inner_block: fn _, _ -> "Dashboard" end}]
      )

    assert html =~ "zaq-link"
    assert html =~ "mt-2"
  end

  defp icon_before_label?(html) do
    {icon_pos, _} = :binary.match(html, "zaq-link__icon")
    {label_pos, _} = :binary.match(html, "zaq-link__label")
    icon_pos < label_pos
  end
end
