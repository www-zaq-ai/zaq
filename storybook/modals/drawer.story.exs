defmodule Storybook.Modals.Drawer do
  use PhoenixStorybook.Story, :page
  use Phoenix.Component

  import ZaqWeb.Components.DesignSystem.Button
  import ZaqWeb.Components.DesignSystem.Input
  import ZaqWeb.Components.Drawer

  @close_event "storybook_close_drawer"
  @module "ZaqWeb.Components.Drawer"

  def description do
    """
    Back-office drawer primitives (`#{@module}`). Slide-over panels for create/edit flows with parent-controlled `is_open`, `DialogOverlay` focus trap, and body scroll lock.
    """
    |> String.trim()
  end

  def render(assigns) do
    assigns =
      assigns
      |> assign(:close_event, @close_event)
      |> assign(:module, @module)

    ~H"""
    <div
      class="zaq-text-body zaq-sandbox"
      style="padding: var(--zaq-scale-32); max-width: 52rem; display: flex; flex-direction: column; gap: var(--zaq-scale-48);"
    >
      <section style="display: flex; flex-direction: column; gap: var(--zaq-scale-16);">
        <h2 class="zaq-text-heading" style="font-size: 1.125rem; margin: 0;">Drawer shell</h2>
        <p class="zaq-text-caption" style="color: var(--zaq-text-color-body-secondary); margin: 0; line-height: 1.6;">
          Module: <code>{@module}</code>. Styling in <code>drawer.css</code>; backdrop reuses <code>.zaq-bo-modal-backdrop</code>.
        </p>
      </section>

      <.doc_section
        id="drawer-right-two-thirds"
        title="form_drawer/1 — right, 2/3 width"
        when_to_use="Default for BO create/edit flows (e.g. Agents). Parent sets `is_open`; pass `on_close` event string or `%JS{}`."
      >
        <.preview_frame label="Right placement, two-thirds width, default padding">
          <.form_drawer
            id="sb-drawer-right"
            is_open={true}
            on_close={@close_event}
            title="Create item"
            placement={:right}
            size={:two_thirds}
          >
            <.input name="demo[name]" label="Name" value="Example" />
            <.input name="demo[description]" type="textarea" label="Description" value="" rows="3" />
            <:actions>
              <.button variant={:secondary} phx-click={@close_event}>Cancel</.button>
              <.button variant={:primary}>Save</.button>
            </:actions>
          </.form_drawer>
        </.preview_frame>
      </.doc_section>

      <.doc_section
        id="drawer-left-one-third"
        title="drawer/1 — left, 1/3 width, flush body"
        when_to_use="Low-level shell with `:header`, body, and `:footer` slots. Use `padding={:flush}` for edge-to-edge body content."
      >
        <.preview_frame label="Left placement, one-third width, flush padding">
          <.drawer
            id="sb-drawer-left"
            is_open={true}
            on_close={@close_event}
            placement={:left}
            size={:one_third}
            padding={:flush}
          >
            <:header>
              <h3 class="zaq-text-h3" style="color: var(--zaq-text-color-body-default); margin: 0;">
                Filters
              </h3>
            </:header>
            <div style="padding: var(--zaq-scale-16) var(--zaq-scale-24);">
              <p class="zaq-text-body-sm" style="color: var(--zaq-text-color-body-tertiary); margin: 0;">
                Flush body — padding applied manually inside the slot when needed.
              </p>
            </div>
          </.drawer>
        </.preview_frame>
      </.doc_section>

      <.doc_section
        id="drawer-top-bottom"
        title="Top and bottom placements"
        when_to_use="Use `size={:one_third}` or `size={:two_thirds}` for viewport height on top/bottom drawers."
      >
        <.preview_frame label="Top, one-third height">
          <.drawer
            id="sb-drawer-top"
            is_open={true}
            on_close={@close_event}
            placement={:top}
            size={:one_third}
          >
            <:header>
              <h3 class="zaq-text-h3" style="color: var(--zaq-text-color-body-default); margin: 0;">
                Top drawer
              </h3>
            </:header>
            <p class="zaq-text-body-sm" style="color: var(--zaq-text-color-body-tertiary);">
              Height is 33.333vh for `:one_third`.
            </p>
          </.drawer>
        </.preview_frame>
        <.preview_frame label="Bottom, two-thirds height">
          <.drawer
            id="sb-drawer-bottom"
            is_open={true}
            on_close={@close_event}
            placement={:bottom}
            size={:two_thirds}
          >
            <:header>
              <h3 class="zaq-text-h3" style="color: var(--zaq-text-color-body-default); margin: 0;">
                Bottom drawer
              </h3>
            </:header>
            <p class="zaq-text-body-sm" style="color: var(--zaq-text-color-body-tertiary);">
              Height is 66.666vh for `:two_thirds`.
            </p>
          </.drawer>
        </.preview_frame>
      </.doc_section>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :when_to_use, :string, required: true
  slot :inner_block, required: true

  defp doc_section(assigns) do
    ~H"""
    <section id={@id} style="display: flex; flex-direction: column; gap: var(--zaq-scale-16);">
      <div style="display: flex; flex-direction: column; gap: var(--zaq-scale-8);">
        <h3 class="zaq-text-heading" style="font-size: 1rem; margin: 0;">{@title}</h3>
        <p class="zaq-text-caption" style="color: var(--zaq-text-color-body-secondary); margin: 0;">
          {@when_to_use}
        </p>
      </div>
      <div style="display: flex; flex-direction: column; gap: var(--zaq-scale-16);">
        {render_slot(@inner_block)}
      </div>
    </section>
    """
  end

  attr :label, :string, required: true
  slot :inner_block, required: true

  defp preview_frame(assigns) do
    ~H"""
    <div style="display: flex; flex-direction: column; gap: var(--zaq-scale-8);">
      <p class="zaq-text-caption" style="color: var(--zaq-text-color-body-tertiary); margin: 0;">
        {@label}
      </p>
      <div
        style="position: relative; min-height: 16rem; border: var(--zaq-border-thickness-default) solid var(--zaq-border-color-default); border-radius: var(--zaq-scale-8); overflow: hidden; background: var(--zaq-surface-color-default);"
      >
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end
end
