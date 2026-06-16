defmodule ZaqWeb.Components.BOModalTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
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

  test "renders modal_shell with default width and overlay cancel event" do
    html =
      render_component(fn assigns ->
        ~H"""
        <BOModal.modal_shell id="generic-modal" cancel_event="close_modal">
          <p>Inner content</p>
        </BOModal.modal_shell>
        """
      end)

    assert html =~ "generic-modal"
    assert html =~ "phx-window-keydown=\"close_modal\""
    assert html =~ "phx-key=\"Escape\""
    assert html =~ "phx-click=\"close_modal\""
    assert html =~ "max-w-sm"
    assert html =~ "zaq-bo-modal-backdrop"
    assert html =~ "zaq-modal"
    assert html =~ "Inner content"
  end

  test "renders form_dialog with actions slot and close button" do
    html =
      render_component(fn assigns ->
        ~H"""
        <BOModal.form_dialog
          id="form-modal"
          cancel_event="cancel_form"
          title="Edit Config"
          body_class="custom-body"
        >
          <div>Form body</div>
          <:actions>
            <button type="button">Cancel</button>
            <button type="submit">Save</button>
          </:actions>
        </BOModal.form_dialog>
        """
      end)

    assert html =~ "form-modal"
    assert html =~ "Edit Config"
    assert html =~ "cancel_form"
    assert html =~ "aria-label=\"Close dialog\""
    assert html =~ "max-h-[90vh]"
    assert html =~ "custom-body"
    assert html =~ "Form body"
    assert html =~ "Save"
  end

  test "form_dialog omits actions container when no actions slot is provided" do
    html =
      render_component(fn assigns ->
        ~H"""
        <BOModal.form_dialog cancel_event="cancel_modal" title="No Actions">
          <div>Body only</div>
        </BOModal.form_dialog>
        """
      end)

    assert html =~ "Body only"
    refute html =~ "justify-end"
  end

  test "iframe_dialog renders iframe and close controls" do
    html =
      render_component(&BOModal.iframe_dialog/1,
        id: "iframe-modal",
        cancel_event: "close_iframe",
        title: "OAuth2 Grant",
        src: "https://example.test/auth",
        height_class: "h-[60vh]"
      )

    assert html =~ "iframe-modal"
    assert html =~ "OAuth2 Grant"
    assert html =~ "src=\"https://example.test/auth\""
    assert html =~ "h-[60vh]"
    assert html =~ "phx-click=\"close_iframe\""
  end
end
