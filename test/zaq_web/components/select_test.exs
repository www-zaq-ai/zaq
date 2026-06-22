defmodule ZaqWeb.SelectTest do
  use ZaqWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ZaqWeb.Select

  test "renders options as list items" do
    html =
      render_component(&Select.select/1,
        name: "role",
        options: [{"Admin", "admin"}, {"User", "user"}],
        value: "user"
      )

    assert html =~ "Admin"
    assert html =~ "User"
  end

  test "renders label when provided" do
    html =
      render_component(&Select.select/1,
        name: "role",
        label: "Role",
        options: [{"Admin", "admin"}],
        value: nil
      )

    assert html =~ "Role"
  end

  test "renders no label element when omitted" do
    html =
      render_component(&Select.select/1,
        name: "role",
        options: [{"Admin", "admin"}],
        value: nil
      )

    refute html =~ ~s(zaq-field-label-uppercase)
  end

  test "renders prompt as empty_label" do
    html =
      render_component(&Select.select/1,
        name: "role",
        prompt: "Choose one",
        options: [{"Admin", "admin"}],
        value: nil
      )

    assert html =~ "Choose one"
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

  test "applies extra class to wrapper" do
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
