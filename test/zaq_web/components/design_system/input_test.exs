defmodule ZaqWeb.Components.DesignSystem.InputTest do
  use ZaqWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ZaqWeb.Components.DesignSystem.Input

  test "input/1 renders text and checkbox variants" do
    text_html =
      render_component(&Input.input/1,
        type: "text",
        id: "username",
        name: "username",
        value: "alice",
        label: "Username",
        errors: ["is invalid"]
      )

    checkbox_html =
      render_component(&Input.input/1,
        type: "checkbox",
        id: "enabled",
        name: "enabled",
        label: "Enabled",
        checked: true
      )

    assert text_html =~ "id=\"username\""
    assert text_html =~ "zaq-control-text"
    assert text_html =~ "zaq-border-danger"
    assert text_html =~ "zaq-field-row-block"
    assert text_html =~ "is invalid"
    assert checkbox_html =~ "type=\"checkbox\""
    assert checkbox_html =~ "Enabled"
  end

  test "input/1 renders hidden and textarea variants" do
    hidden_html =
      render_component(&Input.input/1,
        type: "hidden",
        id: "token",
        name: "token",
        value: "secret"
      )

    textarea_html =
      render_component(&Input.input/1,
        type: "textarea",
        id: "bio",
        name: "bio",
        value: "hello",
        errors: ["too short"],
        error_class: "my-textarea-error"
      )

    assert hidden_html =~ "type=\"hidden\""
    assert hidden_html =~ "value=\"secret\""

    assert textarea_html =~ "<textarea"
    assert textarea_html =~ "zaq-control-text"
    assert textarea_html =~ "hello"
    assert textarea_html =~ "my-textarea-error"
    assert textarea_html =~ "too short"
  end

  test "input/1 keeps zaq-control-text when class is passed" do
    html =
      render_component(&Input.input/1,
        type: "text",
        name: "username",
        class: "w-full"
      )

    assert html =~ "zaq-control-text"
    assert html =~ "w-full"
  end

  test "input/1 with form field supports multiple names" do
    form = Phoenix.Component.to_form(%{"tags" => ["elixir"]}, as: :filters)

    html =
      render_component(&Input.input/1,
        field: form[:tags],
        type: "text",
        multiple: true
      )

    assert html =~ "name=\"filters[tags][]\""
  end

  test "input/1 renders values from form fields across variants" do
    form =
      Phoenix.Component.to_form(
        %{"attempts" => "77", "token" => "secret", "bio" => "hello", "enabled" => true},
        as: :settings
      )

    number_html =
      render_component(&Input.input/1,
        field: form[:attempts],
        type: "number"
      )

    hidden_html = render_component(&Input.input/1, field: form[:token], type: "hidden")
    textarea_html = render_component(&Input.input/1, field: form[:bio], type: "textarea")
    checkbox_html = render_component(&Input.input/1, field: form[:enabled], type: "checkbox")

    assert number_html =~ "id=\"settings_attempts\""
    assert number_html =~ "value=\"77\""
    assert hidden_html =~ "value=\"secret\""
    assert textarea_html =~ "hello</textarea>"
    assert checkbox_html =~ "checked"
  end

  test "input/1 preserves an explicit value over a form field value" do
    form = Phoenix.Component.to_form(%{"attempts" => "77"}, as: :settings)

    html =
      render_component(&Input.input/1,
        field: form[:attempts],
        type: "number",
        value: "12"
      )

    assert html =~ "value=\"12\""
    refute html =~ "value=\"77\""
  end
end
