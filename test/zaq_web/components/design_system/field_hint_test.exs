defmodule ZaqWeb.Components.DesignSystem.FieldHintTest do
  use ZaqWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ZaqWeb.Components.DesignSystem.FieldHint

  test "error ids are optional and unique for multiple messages" do
    html =
      render_component(&FieldHint.field_messages/1,
        errors: ["First", "Second"],
        error_id: "field-error"
      )

    tree = LazyHTML.from_fragment(html)
    assert Enum.count(LazyHTML.query(tree, "#field-error.zaq-field-error")) == 1
    assert Enum.count(LazyHTML.query(tree, "#field-error-1.zaq-field-error")) == 1
  end

  test "field_messages/1 renders errors and hides hint" do
    html =
      render_component(&FieldHint.field_messages/1,
        errors: ["can't be blank"],
        hint: "Should not show",
        hint_tone: :success
      )

    assert html =~ "can&#39;t be blank"
    assert html =~ "zaq-field-error"
    refute html =~ "Should not show"
  end

  test "field_messages/1 renders hint tones" do
    info =
      render_component(&FieldHint.field_messages/1,
        hint: "Optional note",
        hint_tone: :info,
        hint_id: "field-hint"
      )

    assert info =~ "Optional note"
    assert info =~ "zaq-field-hint--info"

    success =
      render_component(&FieldHint.field_messages/1,
        hint: "Passwords match",
        hint_tone: :success,
        hint_id: "password-confirmation-status"
      )

    assert success =~ "Passwords match"
    assert success =~ "zaq-field-hint--success"
    assert success =~ ~s(id="password-confirmation-status")
  end
end
