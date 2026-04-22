defmodule ZaqWeb.CoreComponentsTest do
  use ZaqWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ZaqWeb.CoreComponents
  alias Phoenix.LiveView.JS
  alias Phoenix.LiveView.LiveStream

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

  test "flash/1 renders title, explicit id, and rest attrs" do
    html =
      render_component(&CoreComponents.flash/1,
        id: "custom-flash",
        kind: :info,
        flash: %{"info" => "Updated"},
        title: "Success",
        data_testid: "flash-custom"
      )

    assert html =~ "id=\"custom-flash\""
    assert html =~ "Success"
    assert html =~ "Updated"
    assert html =~ "data_testid=\"flash-custom\""
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

  test "button/1 honors explicit class override and patch links" do
    html =
      render_component(&CoreComponents.button/1,
        class: "btn btn-neutral",
        patch: "/bo/users",
        inner_block: [%{inner_block: fn _, _ -> "Users" end}]
      )

    assert html =~ "href=\"/bo/users\""
    assert html =~ "btn btn-neutral"
    refute html =~ "btn-primary"
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

  test "input/1 select supports multiple and no prompt" do
    html =
      render_component(&CoreComponents.input/1,
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

  test "secret_input/1 renders explicit assigns and custom classes" do
    html =
      render_component(&CoreComponents.secret_input/1,
        id: "api-token",
        name: "token",
        value: "s3cr3t",
        placeholder: "••••••",
        input_class: "my-secret-input",
        button_class: "my-secret-button",
        wrapper_class: "my-secret-wrapper",
        "phx-debounce": "300"
      )

    assert html =~ "id=\"api-token\""
    assert html =~ "name=\"token\""
    assert html =~ "type=\"password\""
    assert html =~ "my-secret-input"
    assert html =~ "my-secret-button"
    assert html =~ "my-secret-wrapper"
    assert html =~ "eye-on"
    assert html =~ "eye-off"
    assert html =~ "phx-debounce=\"300\""
  end

  test "secret_input/1 supports form field and renders field errors" do
    form =
      Phoenix.Component.to_form(
        %{"password" => "hunter2"},
        as: :user,
        errors: [password: {"can't be blank", []}],
        action: :validate
      )

    html =
      render_component(&CoreComponents.secret_input/1,
        field: form[:password]
      )

    assert html =~ "id=\"secret-user-password-\""
    assert html =~ "name=\"user[password]\""
    assert html =~ "can&#39;t be blank"
  end

  test "secret_input/1 derives stable ids when missing explicit id" do
    binary_name_html =
      render_component(&CoreComponents.secret_input/1,
        name: "credentials[token]",
        value: nil
      )

    nil_name_html =
      render_component(&CoreComponents.secret_input/1,
        name: nil,
        value: nil
      )

    atom_name_html =
      render_component(&CoreComponents.secret_input/1,
        name: :api_token,
        value: nil
      )

    assert binary_name_html =~ "id=\"secret-credentials-token-\""
    assert nil_name_html =~ "id=\"secret-input\""
    assert atom_name_html =~ "id=\"secret-api_token\""
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

  test "table/1 renders rows without action slot" do
    html =
      render_component(&CoreComponents.table/1,
        id: "rows-no-action",
        rows: [%{id: 2, name: "Bob"}],
        row_id: fn row -> "row-#{row.id}" end,
        col: [
          %{label: "Name", inner_block: fn _, _ -> "Bob" end}
        ]
      )

    assert html =~ "id=\"rows-no-action\""
    assert html =~ "id=\"row-2\""
    refute html =~ "Actions"
  end

  test "table/1 supports LiveStream rows and default row_id" do
    stream =
      LiveStream.new(:users, "ref-1", [%{id: 7, name: "Dana"}], [])
      |> LiveStream.mark_consumable()

    html =
      render_component(&CoreComponents.table/1,
        id: "users-stream",
        rows: stream,
        col: [
          %{label: "Name", inner_block: fn _, {_, row} -> row.name end}
        ]
      )

    assert html =~ "phx-update=\"stream\""
    assert html =~ "id=\"users-7\""
    assert html =~ "Dana"
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

  test "translate_error/1 handles non-count option" do
    assert CoreComponents.translate_error({"can't be blank", []}) == "can't be blank"
  end

  test "show/2 and hide/2 build JS operations" do
    assert %JS{ops: [["show", show_opts]]} = CoreComponents.show("#modal")
    assert show_opts[:to] == "#modal"
    assert show_opts[:time] == 300

    assert %JS{ops: [["show", show_opts2]]} = CoreComponents.show(%JS{}, "#panel")
    assert show_opts2[:to] == "#panel"
    assert show_opts2[:time] == 300

    assert %JS{ops: [["hide", hide_opts]]} = CoreComponents.hide("#modal")
    assert hide_opts[:to] == "#modal"
    assert hide_opts[:time] == 200

    assert %JS{ops: [["hide", hide_opts2]]} = CoreComponents.hide(%JS{}, "#panel")
    assert hide_opts2[:to] == "#panel"
    assert hide_opts2[:time] == 200
  end
end
