defmodule ZaqWeb.Components.DesignSystem.CheckboxTest do
  use ZaqWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ZaqWeb.Components.DesignSystem.Checkbox

  test "checkbox/1 renders labelled variant with hidden false input" do
    html =
      render_component(&Checkbox.checkbox/1,
        id: "notify",
        name: "notify",
        label: "Email notifications",
        value: true
      )

    assert html =~ "type=\"checkbox\""
    assert html =~ "type=\"hidden\""
    assert html =~ "value=\"false\""
    assert html =~ "Email notifications"
    assert html =~ "zaq-bo-checkbox"
    assert html =~ "zaq-checkbox-label"
    assert html =~ "checked"
  end

  test "checkbox/1 renders bare variant without label wrapper" do
    html =
      render_component(&Checkbox.checkbox/1,
        id: "select-row",
        checked: true
      )

    assert html =~ "type=\"checkbox\""
    assert html =~ "zaq-bo-checkbox"
    refute html =~ "zaq-checkbox-label"
    refute html =~ "type=\"hidden\""
  end

  test "checkbox/1 renders bare variant with form hidden input when name is set" do
    html =
      render_component(&Checkbox.checkbox/1,
        id: "select-all",
        name: "select_all",
        checked: false
      )

    assert html =~ "type=\"hidden\""
    assert html =~ "name=\"select_all\""
    refute html =~ "zaq-checkbox-label"
  end

  test "checkbox/1 with form field derives checked state" do
    form = Phoenix.Component.to_form(%{"enabled" => "true"}, as: :settings)

    html =
      render_component(&Checkbox.checkbox/1,
        field: form[:enabled],
        label: "Enabled"
      )

    assert html =~ "name=\"settings[enabled]\""
    assert html =~ "Enabled"
    assert html =~ "checked"
  end

  test "checkbox/1 with form field honors explicit name override" do
    form = Phoenix.Component.to_form(%{"enabled" => "true"}, as: :settings)

    html =
      render_component(&Checkbox.checkbox/1,
        field: form[:enabled],
        name: "settings[enabled_override]",
        label: "Enabled"
      )

    assert html =~ "name=\"settings[enabled_override]\""
    refute html =~ "name=\"settings[enabled]\""
    assert html =~ "id=\"settings_enabled\""
    assert html =~ "Enabled"
    assert html =~ "checked"
  end

  test "checkbox/1 renders validation errors" do
    html =
      render_component(&Checkbox.checkbox/1,
        id: "terms",
        name: "terms",
        label: "Accept terms and conditions",
        value: false,
        errors: ["must be accepted"]
      )

    assert html =~ "must be accepted"
  end
end
