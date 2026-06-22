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

  test "input/1 renders hidden, select, and textarea variants" do
    hidden_html =
      render_component(&Input.input/1,
        type: "hidden",
        id: "token",
        name: "token",
        value: "secret"
      )

    select_html =
      render_component(&Input.input/1,
        type: "select",
        id: "role",
        name: "role",
        label: "Role",
        value: "admin",
        prompt: "Choose one",
        options: [{"Admin", "admin"}, {"User", "user"}],
        errors: ["invalid"],
        error_class: "my-select-error"
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

    assert select_html =~ "<select"
    assert select_html =~ "Choose one"
    assert select_html =~ "my-select-error"

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

  test "input/1 select supports multiple and no prompt" do
    html =
      render_component(&Input.input/1,
        type: "select",
        id: "agents",
        name: "agents",
        options: [{"Agent A", 1}, {"Agent B", 2}],
        value: [1],
        multiple: true
      )

    assert html =~ "<select"
    assert html =~ "multiple"
    refute html =~ "<option value=\"\""
  end
end
