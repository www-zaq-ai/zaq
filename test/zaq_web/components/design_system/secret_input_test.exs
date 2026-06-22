defmodule ZaqWeb.Components.DesignSystem.SecretInputTest do
  use ZaqWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ZaqWeb.Components.DesignSystem.SecretInput

  test "secret_input/1 renders explicit assigns and custom classes" do
    html =
      render_component(&SecretInput.secret_input/1,
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
      render_component(&SecretInput.secret_input/1,
        field: form[:password]
      )

    assert html =~ "id=\"secret-user-password-\""
    assert html =~ "name=\"user[password]\""
    assert html =~ "can&#39;t be blank"
  end

  test "secret_input/1 derives stable ids when missing explicit id" do
    binary_name_html =
      render_component(&SecretInput.secret_input/1,
        name: "credentials[token]",
        value: nil
      )

    nil_name_html =
      render_component(&SecretInput.secret_input/1,
        name: nil,
        value: nil
      )

    atom_name_html =
      render_component(&SecretInput.secret_input/1,
        name: :api_token,
        value: nil
      )

    assert binary_name_html =~ "id=\"secret-credentials-token-\""
    assert nil_name_html =~ "id=\"secret-input\""
    assert atom_name_html =~ "id=\"secret-api_token\""
  end
end
