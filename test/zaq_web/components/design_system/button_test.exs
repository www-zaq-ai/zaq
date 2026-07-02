defmodule ZaqWeb.Components.DesignSystem.ButtonTest do
  use ZaqWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ZaqWeb.Components.DesignSystem.Button

  test "button/1 primary renders zaq-btn shell and label typography" do
    html =
      render_component(&Button.button/1,
        inner_block: [%{inner_block: fn _, _ -> "Save" end}]
      )

    assert html =~ "zaq-btn "
    assert html =~ "zaq-btn-primary"
    assert html =~ "zaq-btn-text_label-default"
    assert html =~ "Save"
    refute html =~ "phx-hook"
  end

  test "button/1 secondary ghost tertiary variants" do
    for {variant, class} <- [
          {:secondary, "zaq-btn-secondary"},
          {:ghost, "zaq-btn-ghost"},
          {:tertiary, "zaq-btn-tertiary"}
        ] do
      html =
        render_component(&Button.button/1,
          variant: variant,
          inner_block: [%{inner_block: fn _, _ -> "Action" end}]
        )

      assert html =~ class
    end
  end

  test "button/1 pill shape uses zaq-btn-pill" do
    html =
      render_component(&Button.button/1,
        shape: :pill,
        variant: :secondary,
        inner_block: [%{inner_block: fn _, _ -> "Chip" end}]
      )

    assert html =~ "zaq-btn-pill"
    assert html =~ "zaq-btn-secondary"
  end

  test "button/1 tertiary active and danger modifiers" do
    html =
      render_component(&Button.button/1,
        variant: :tertiary,
        active: true,
        danger: true,
        inner_block: [%{inner_block: fn _, _ -> "Delete" end}]
      )

    assert html =~ "zaq-btn-tertiary--active"
    assert html =~ "zaq-btn-danger"
  end

  test "button/1 with icon left and right" do
    left_html =
      render_component(&Button.button/1,
        variant: :primary,
        icon: "hero-x-mark",
        icon_position: :left,
        inner_block: [%{inner_block: fn _, _ -> "Dismiss" end}]
      )

    assert left_html =~ "hero-x-mark"
    assert left_html =~ "Dismiss"
    assert icon_before_text?(left_html, "Dismiss", "hero-x-mark")

    right_html =
      render_component(&Button.button/1,
        variant: :primary,
        icon: "hero-x-mark",
        icon_position: :right,
        inner_block: [%{inner_block: fn _, _ -> "Dismiss" end}]
      )

    refute icon_before_text?(right_html, "Dismiss", "hero-x-mark")
  end

  test "button/1 icon_only uses zaq-btn-icon without label typography" do
    html =
      render_component(&Button.button/1,
        variant: :ghost,
        icon_only: true,
        icon: "hero-trash",
        "aria-label": "Delete",
        inner_block: []
      )

    assert html =~ "zaq-btn-icon"
    assert html =~ "hero-trash"
    refute html =~ "zaq-btn-text_label-default"
    assert html =~ ~s(aria-label="Delete")
  end

  test "button/1 navigate renders link with button classes" do
    html =
      render_component(&Button.button/1,
        navigate: "/bo/dashboard",
        variant: :secondary,
        inner_block: [%{inner_block: fn _, _ -> "Dashboard" end}]
      )

    assert html =~ "<a"
    assert html =~ "zaq-btn-secondary"
    assert html =~ "/bo/dashboard"
    assert html =~ "Dashboard"
  end

  test "button/1 loading adds hook and loading spans" do
    html =
      render_component(&Button.button/1,
        variant: :primary,
        loading: true,
        loading_label: "Running…",
        phx_click: "run",
        inner_block: [%{inner_block: fn _, _ -> "Run" end}]
      )

    assert html =~ ~s(phx-hook="LoadingActionButton")
    assert html =~ "zaq-btn__label"
    assert html =~ "zaq-btn__loading"
    assert html =~ "Running…"
    assert html =~ "hero-arrow-path"
    assert html =~ "phx-click-loading_.zaq-btn__label"
  end

  test "button/1 loading on link button omits hook" do
    html =
      render_component(&Button.button/1,
        navigate: "/bo/dashboard",
        loading: true,
        inner_block: [%{inner_block: fn _, _ -> "Go" end}]
      )

    refute html =~ "phx-hook"
    refute html =~ "zaq-btn__loading"
  end

  test "button/1 tertiary with icon renders hero icon" do
    html =
      render_component(&Button.button/1,
        variant: :tertiary,
        icon: "hero-arrows-pointing-out",
        inner_block: [%{inner_block: fn _, _ -> "Move" end}]
      )

    assert html =~ "zaq-btn-tertiary"
    assert html =~ "hero-arrows-pointing-out"
    assert html =~ "Move"
    assert icon_before_text?(html, "Move", "hero-arrows-pointing-out")
  end

  test "button/1 merges optional class attribute" do
    html =
      render_component(&Button.button/1,
        class: "w-full",
        inner_block: [%{inner_block: fn _, _ -> "Full width" end}]
      )

    assert html =~ "w-full"
    assert html =~ "zaq-btn-primary"
  end

  defp icon_before_text?(html, text, icon) do
    {icon_pos, _} = :binary.match(html, icon)
    {text_pos, _} = :binary.match(html, text)
    icon_pos < text_pos
  end
end
