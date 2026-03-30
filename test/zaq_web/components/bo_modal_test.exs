defmodule ZaqWeb.Components.BOModalTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ZaqWeb.Components.BOModal

  test "renders confirm dialog with expected events and labels" do
    html =
      render_component(&BOModal.confirm_dialog/1,
        id: "confirm-delete-modal",
        title: "Confirm Delete",
        message: "Delete this item?",
        cancel_event: "cancel_delete",
        confirm_event: "delete",
        confirm_button_id: "delete-item-button"
      )

    assert html =~ "confirm-delete-modal"
    assert html =~ "phx-window-keydown=\"cancel_delete\""
    assert html =~ "phx-click=\"cancel_delete\""
    assert html =~ "phx-click=\"delete\""
    assert html =~ "delete-item-button"
    assert html =~ "Confirm Delete"
    assert html =~ "Delete this item?"
  end
end
