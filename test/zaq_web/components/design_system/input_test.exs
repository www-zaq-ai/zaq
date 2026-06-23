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
    assert text_html =~ "input-error"
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
    assert textarea_html =~ "hello"
    assert textarea_html =~ "my-textarea-error"
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
end
