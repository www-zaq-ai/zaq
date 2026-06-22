defmodule ZaqWeb.SelectTest do
  use ZaqWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ZaqWeb.Select

  test "renders a select with options" do
    html =
      render_component(&Select.select/1,
        name: "role",
        options: [{"Admin", "admin"}, {"User", "user"}],
        value: "user"
      )

    assert html =~ ~s(<select)
    assert html =~ ~s(name="role")
    assert html =~ ~s(zaq-control-select)
    assert html =~ "Admin"
    assert html =~ "User"
    assert html =~ ~s(selected)
  end

  test "renders label when provided" do
    html =
      render_component(&Select.select/1,
        name: "role",
        label: "Role",
        options: [{"Admin", "admin"}],
        value: nil
      )

    assert html =~ ~s(class="zaq-field-label-uppercase")
    assert html =~ "Role"
  end

  test "renders no label when omitted" do
    html =
      render_component(&Select.select/1,
        name: "role",
        options: [{"Admin", "admin"}],
        value: nil
      )

    refute html =~ "zaq-field-label-uppercase"
  end

  test "renders prompt option" do
    html =
      render_component(&Select.select/1,
        name: "role",
        prompt: "Choose one",
        options: [{"Admin", "admin"}],
        value: nil
      )

    assert html =~ ~s(<option value="">Choose one</option>)
  end

  test "renders validation errors" do
    html =
      render_component(&Select.select/1,
        name: "role",
        options: [{"Admin", "admin"}],
        value: nil,
        errors: ["can't be blank"]
      )

    assert html =~ "can&#39;t be blank"
  end

  test "renders no error markup when errors list is empty" do
    html =
      render_component(&Select.select/1,
        name: "role",
        options: [{"Admin", "admin"}],
        value: nil,
        errors: []
      )

    refute html =~ "text-error"
  end

  test "supports multiple selection" do
    html =
      render_component(&Select.select/1,
        name: "roles",
        options: [{"Admin", "admin"}, {"User", "user"}],
        value: ["admin", "user"],
        multiple: true
      )

    assert html =~ ~s(multiple)
  end

  test "applies extra class" do
    html =
      render_component(&Select.select/1,
        name: "role",
        options: [],
        value: nil,
        class: "max-w-sm"
      )

    assert html =~ "max-w-sm"
  end
end
