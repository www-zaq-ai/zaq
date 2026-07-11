defmodule ZaqWeb.Components.DesignSystem.ToggleTest do
  use ZaqWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ZaqWeb.Components.DesignSystem.Toggle

  test "renders icon-only segments with dynamic phx-value param" do
    html =
      render_component(&Toggle.toggle/1,
        value: "list",
        event: "toggle_view_mode",
        value_param: "mode",
        choices: [
          %{value: "list", icon: "hero-bars-3", title: "List view"},
          %{value: "grid", icon: "hero-squares-2x2", title: "Grid view"}
        ]
      )

    assert html =~ "phx-click=\"toggle_view_mode\""
    assert html =~ "phx-value-mode=\"list\""
    assert html =~ "phx-value-mode=\"grid\""
    assert html =~ "zaq-toggle-segment--active"
    assert html =~ "zaq-text-body"
    assert html =~ "hero-bars-3"
    assert html =~ ~s(aria-label="List view")
    refute html =~ "zaq-toggle-segment--with-label"
  end

  test "renders text-only and text+icon segments with suffix" do
    html =
      render_component(&Toggle.toggle/1,
        value: "b",
        event: "pick",
        suffix: "3 options",
        choices: [
          %{value: "a", label: "Alpha"},
          %{value: "b", label: "Beta", icon: "hero-check"},
          %{value: "c", label: "Gamma"}
        ]
      )

    assert html =~ "Alpha"
    assert html =~ "Beta"
    assert html =~ "Gamma"
    assert html =~ "hero-check"
    assert html =~ "zaq-toggle-segment--with-label"
    assert html =~ "zaq-toggle-segment--text-only"
    assert html =~ "3 options"
    assert html =~ "phx-value-value=\"b\""
  end

  test "renders channel provider icon with label" do
    html =
      render_component(&Toggle.toggle/1,
        value: "provider:google_drive",
        event: "switch_source",
        value_param: "source",
        choices: [
          %{value: "volume:documents", label: "documents", provider: "zaq_local"},
          %{value: "provider:google_drive", label: "Google Drive", provider: "google_drive"}
        ]
      )

    assert html =~ "zaq-toggle-segment--with-label"
    assert html =~ "fill=\"#0066da\""
    assert html =~ ~s(<rect x="3" y="4")
  end

  test "renders pill variant for three icon choices" do
    html =
      render_component(&Toggle.toggle/1,
        value: "dark",
        event: "set_theme",
        value_param: "theme",
        variant: :pill,
        choices: [
          %{value: "system", icon: "hero-computer-desktop-micro", title: "System"},
          %{value: "light", icon: "hero-sun-micro", title: "Light"},
          %{value: "dark", icon: "hero-moon-micro", title: "Dark"}
        ]
      )

    assert html =~ "zaq-toggle-group-pill"
    assert count_occurrences(html, "class=\"zaq-toggle-segment") == 3
    assert html =~ "phx-value-theme=\"dark\""
  end

  defp count_occurrences(haystack, needle) do
    haystack
    |> String.split(needle)
    |> length()
    |> Kernel.-(1)
  end
end
