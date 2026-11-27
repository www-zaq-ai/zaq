defmodule ZaqWeb.Components.ConnectionSettingsTest do
  use ZaqWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Phoenix.Component

  alias ZaqWeb.Components.ConnectionSettings

  test "settings selection reuses Toggle native buttons and exposes pressed state and errors" do
    html =
      render_component(fn assigns ->
        ~H"""
        <ConnectionSettings.editor id="settings" active_tab={:main} errors={%{advanced: true}}>
          <:main><input name="name" value="Draft" /></:main>
          <:advanced id="files" label="File delivery">
            File controls <input name="file_limit" value="1.000001" />
            <input type="hidden" name="failure_policy" value="false" />
          </:advanced>
        </ConnectionSettings.editor>
        """
      end)

    tree = LazyHTML.from_fragment(html)

    assert Enum.count(
             LazyHTML.query(
               tree,
               "#settings-selector[role=group][aria-label='Connection settings'] .zaq-toggle-group button[type=button]"
             )
           ) == 2

    assert Enum.count(
             LazyHTML.query(tree, "button[phx-value-tab=main][aria-pressed=true]:not([tabindex])")
           ) == 1

    assert Enum.count(
             LazyHTML.query(
               tree,
               "button[phx-value-tab=advanced][aria-pressed=false]:not([tabindex])"
             )
           ) == 1

    assert LazyHTML.text(LazyHTML.query(tree, "button[phx-value-tab=advanced]")) =~ "Errors"
    assert Enum.empty?(LazyHTML.query(tree, "[role=tab], [role=tablist], [phx-hook]"))

    refute Enum.empty?(
             LazyHTML.query(tree, "#settings-panel-main:not([hidden]) input[name=name]")
           )

    refute Enum.empty?(
             LazyHTML.query(
               tree,
               "#settings-panel-advanced[hidden] input[name=file_limit][value='1.000001']"
             )
           )

    assert LazyHTML.query(tree, "#files h3") |> LazyHTML.text() == "File delivery"

    refute Enum.empty?(
             LazyHTML.query(tree, "input[name=failure_policy][value=false]:not([disabled])")
           )

    assert Enum.empty?(LazyHTML.query(tree, "input[disabled], form, button[type=submit]"))
  end

  test "no advanced sections means Main only and error selection remains Main-first" do
    html =
      render_component(fn assigns ->
        ~H"""
        <ConnectionSettings.editor id="simple" active_tab={:advanced}>
          <:main><input name="name" value="Visible" /></:main>
        </ConnectionSettings.editor>
        """
      end)

    tree = LazyHTML.from_fragment(html)
    refute Enum.empty?(LazyHTML.query(tree, "input[name=name]"))
    assert Enum.empty?(LazyHTML.query(tree, "[hidden], #simple-selector, button"))
    assert ConnectionSettings.tab_for_errors(:advanced, %{main: true, advanced: true}) == :main
    assert ConnectionSettings.tab_for_errors(:main, %{advanced: true}) == :advanced
    assert ConnectionSettings.tab_for_errors(:advanced, %{}) == :advanced
  end
end
