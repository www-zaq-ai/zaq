defmodule ZaqWeb.Components.BOModalTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import ZaqWeb.Components.DesignSystem.Button

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
    assert html =~ "zaq-modal--width-sm"
    assert html =~ "zaq-bo-modal-overlay"
    assert html =~ "zaq-bo-modal-backdrop"
    assert html =~ "zaq-modal"
    assert html =~ "Inner content"
  end

  test "renders modal_shell with shared header when title is set" do
    html =
      render_component(fn assigns ->
        ~H"""
        <BOModal.modal_shell
          id="titled-modal"
          cancel_event="close_modal"
          title="Add tools"
          max_width_class="zaq-modal--width-lg"
        >
          <p>Picker body</p>
        </BOModal.modal_shell>
        """
      end)

    assert html =~ "titled-modal"
    assert html =~ "zaq-modal-header"
    assert html =~ "zaq-modal-body"
    assert html =~ "Add tools"
    assert html =~ ~s(id="titled-modal-title")
    assert html =~ "Picker body"
    assert html =~ "zaq-modal--form"
    assert html =~ "hero-x-mark"
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
            <.button variant={:secondary} phx-click="cancel_form">Cancel</.button>
            <.button variant={:primary} type="submit">Save</.button>
          </:actions>
        </BOModal.form_dialog>
        """
      end)

    assert html =~ "form-modal"
    assert html =~ "Edit Config"
    assert html =~ "cancel_form"
    assert html =~ ~s(role="dialog")
    assert html =~ ~s(aria-modal="true")
    assert html =~ ~s(aria-labelledby="form-modal-title")
    assert html =~ ~s(id="form-modal-title")
    assert html =~ "aria-label=\"Close dialog\""
    assert html =~ "zaq-modal--form"
    assert html =~ "zaq-modal-header"
    assert html =~ "zaq-btn-icon"
    assert html =~ "hero-x-mark"
    assert html =~ "custom-body"
    assert html =~ "Form body"
    assert html =~ "Save"
    assert html =~ "zaq-btn-primary"
    assert html =~ "zaq-btn-secondary"
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
    refute html =~ "zaq-modal-form-footer"
    assert html =~ ~s(role="dialog")
    assert html =~ ~s(aria-modal="true")
    assert html =~ ~s(aria-label="No Actions")
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
