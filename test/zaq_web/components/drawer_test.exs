defmodule ZaqWeb.Components.DrawerTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias ZaqWeb.Components.Drawer

  test "renders drawer when is_open is true with overlay, backdrop, and panel" do
    html =
      render_component(fn assigns ->
        ~H"""
        <Drawer.drawer
          id="demo-drawer"
          is_open={true}
          on_close="close_drawer"
          placement={:right}
          size={:two_thirds}
          padding={:default}
        >
          <:header>
            <h3 class="zaq-text-h3">Create item</h3>
          </:header>
          <p>Body content</p>
          <:footer>
            <button type="button" class="zaq-btn zaq-btn-secondary">Cancel</button>
          </:footer>
        </Drawer.drawer>
        """
      end)

    assert html =~ "demo-drawer"
    assert html =~ "phx-hook=\"DialogOverlay\""
    assert html =~ "phx-window-keydown=\"close_drawer\""
    assert html =~ "phx-key=\"Escape\""
    assert html =~ "phx-click=\"close_drawer\""
    assert html =~ "zaq-drawer-overlay"
    assert html =~ "zaq-bo-modal-backdrop"
    assert html =~ "zaq-drawer-panel"
    assert html =~ "zaq-drawer--right"
    assert html =~ "zaq-drawer--size-two-thirds"
    assert html =~ "zaq-drawer-body--padded"
    assert html =~ "role=\"dialog\""
    assert html =~ "aria-modal=\"true\""
    assert html =~ "Body content"
    assert html =~ "Close drawer"
  end

  test "does not render drawer when is_open is false" do
    html =
      render_component(fn assigns ->
        ~H"""
        <Drawer.drawer id="demo-drawer" is_open={false} on_close="close_drawer">
          <p>Hidden</p>
        </Drawer.drawer>
        """
      end)

    refute html =~ "zaq-drawer-overlay"
    refute html =~ "Hidden"
  end

  test "renders top placement with one_third height and flush padding" do
    html =
      render_component(fn assigns ->
        ~H"""
        <Drawer.drawer
          id="top-drawer"
          is_open={true}
          on_close="close_drawer"
          placement={:top}
          size={:one_third}
          padding={:flush}
          return_focus_id="open-button"
        >
          <p>Flush body</p>
        </Drawer.drawer>
        """
      end)

    assert html =~ "zaq-drawer--top"
    assert html =~ "zaq-drawer--size-one-third"
    assert html =~ "zaq-drawer-body--flush"
    assert html =~ ~s(data-return-focus-id="open-button")
  end

  test "renders form_drawer with title and actions slot" do
    html =
      render_component(fn assigns ->
        ~H"""
        <Drawer.form_drawer
          id="form-drawer"
          is_open={true}
          on_close="close_drawer"
          title="Edit record"
        >
          <p>Form fields</p>
          <:actions>
            <button type="button" class="zaq-btn zaq-btn-primary">Save</button>
          </:actions>
        </Drawer.form_drawer>
        """
      end)

    assert html =~ "form-drawer"
    assert html =~ "Edit record"
    assert html =~ ~s(id="form-drawer-title")
    assert html =~ "Form fields"
    assert html =~ "zaq-drawer-footer"
    assert html =~ "Save"
  end
end
