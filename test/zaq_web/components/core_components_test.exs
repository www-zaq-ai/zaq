defmodule ZaqWeb.CoreComponentsTest do
  use ZaqWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ZaqWeb.CoreComponents

  test "flash/1 renders info flash from map" do
    html =
      render_component(&CoreComponents.flash/1,
        kind: :info,
        flash: %{},
        inner_block: [%{inner_block: fn _, _ -> "Saved" end}]
      )

    assert html =~ "id=\"flash-info\""
    assert html =~ "Saved"
    assert html =~ "alert-info"
  end

  test "flash/1 renders flash map message when no inner block" do
    html =
      render_component(&CoreComponents.flash/1,
        kind: :error,
        flash: %{"error" => "Nope"}
      )

    assert html =~ "id=\"flash-error\""
    assert html =~ "Nope"
    assert html =~ "alert-error"
  end

  test "flash/1 renders nothing when there is no message" do
    html = render_component(&CoreComponents.flash/1, kind: :info, flash: %{})

    assert String.trim(html) == ""
  end

  test "button/1 renders button and link variants" do
    button_html =
      render_component(&CoreComponents.button/1,
        inner_block: [%{inner_block: fn _, _ -> "Save" end}]
      )

    link_html =
      render_component(&CoreComponents.button/1,
        navigate: "/bo/dashboard",
        inner_block: [%{inner_block: fn _, _ -> "Go" end}]
      )

    assert button_html =~ "<button"
    assert button_html =~ "Save"
    assert link_html =~ "<a"
    assert link_html =~ "href=\"/bo/dashboard\""
  end

  test "button/1 applies explicit primary variant classes" do
    html =
      render_component(&CoreComponents.button/1,
        variant: "primary",
        inner_block: [%{inner_block: fn _, _ -> "Create" end}]
      )

    assert html =~ "btn"
    assert html =~ "btn-primary"
    refute html =~ "btn-soft"
  end

  test "input/1 renders text and checkbox variants" do
    text_html =
      render_component(&CoreComponents.input/1,
        type: "text",
        id: "username",
        name: "username",
        value: "alice",
        label: "Username",
        errors: ["is invalid"]
      )

    checkbox_html =
      render_component(&CoreComponents.input/1,
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
      render_component(&CoreComponents.input/1,
        type: "hidden",
        id: "token",
        name: "token",
        value: "secret"
      )

    select_html =
      render_component(&CoreComponents.input/1,
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
      render_component(&CoreComponents.input/1,
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
      render_component(&CoreComponents.input/1,
        field: form[:tags],
        type: "text",
        multiple: true
      )

    assert html =~ "name=\"filters[tags][]\""
  end

  test "header/1 and list/1 render optional slots" do
    header_html =
      render_component(&CoreComponents.header/1,
        inner_block: [%{inner_block: fn _, _ -> "Users" end}],
        subtitle: [%{inner_block: fn _, _ -> "Manage users" end}],
        actions: [%{inner_block: fn _, _ -> "New" end}]
      )

    list_html =
      render_component(&CoreComponents.list/1,
        item: [
          %{title: "Name", inner_block: fn _, _ -> "Alice" end},
          %{title: "Role", inner_block: fn _, _ -> "Admin" end}
        ]
      )

    assert header_html =~ "Users"
    assert header_html =~ "Manage users"
    assert header_html =~ "New"

    assert list_html =~ "Name"
    assert list_html =~ "Alice"
    assert list_html =~ "Role"
  end

  test "table/1 renders action column and clickable rows" do
    html =
      render_component(&CoreComponents.table/1,
        id: "users",
        rows: [%{id: 1, name: "Alice"}],
        row_id: fn row -> "user-#{row.id}" end,
        row_click: fn row -> "show-#{row.id}" end,
        col: [
          %{label: "Name", inner_block: fn _, _ -> "Alice" end}
        ],
        action: [
          %{inner_block: fn _, _ -> "Edit" end}
        ]
      )

    assert html =~ "id=\"users\""
    assert html =~ "id=\"user-1\""
    assert html =~ "phx-click=\"show-1\""
    assert html =~ "Actions"
    assert html =~ "Edit"
  end

  test "icon/1 renders hero class names" do
    html = render_component(&CoreComponents.icon/1, name: "hero-x-mark")

    assert html =~ "hero-x-mark"
    assert html =~ "size-4"
  end

  test "translate_errors/2 returns translated field errors" do
    errors = [username: {"can't be blank", []}, password: {"is too short", [count: 8]}]

    assert CoreComponents.translate_errors(errors, :username) == ["can't be blank"]
    assert CoreComponents.translate_errors(errors, :password) == ["is too short"]
    assert CoreComponents.translate_errors(errors, :role_id) == []
  end

  test "translate_error/1 handles pluralization count option" do
    assert CoreComponents.translate_error({"is too short", [count: 3]}) == "is too short"
  end
end
