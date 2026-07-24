defmodule ZaqWeb.Components.Drawer do
  @moduledoc """
  Reusable Back Office drawer primitive.

  Parent LiveViews own visibility via `is_open` — this component does not manage
  open/close state internally. Pass `on_close` as a LiveView event string or
  `%Phoenix.LiveView.JS{}` for backdrop, Escape, and header close actions.

  Includes `DialogOverlay` hook for focus trap and body scroll lock (shared hook
  intended for future `BOModal` retrofit).

  - `drawer/1` — low-level shell with `:header`, default body, and `:footer` slots.
  - `form_drawer/1` — composed create/edit drawer with title header and footer actions slot.
  """

  use ZaqWeb, :html

  alias ZaqWeb.Components.DesignSystem.Button, as: DSButton

  attr :id, :string, required: true
  attr :is_open, :boolean, required: true
  attr :on_close, :any, required: true
  attr :placement, :atom, default: :right, values: [:left, :right, :top, :bottom]
  attr :size, :atom, default: :two_thirds, values: [:one_third, :two_thirds]
  attr :padding, :atom, default: :default, values: [:default, :flush]
  attr :return_focus_id, :string, default: nil
  attr :title_id, :string, default: nil
  attr :backdrop_class, :string, default: "zaq-bo-modal-backdrop"
  attr :panel_class, :string, default: ""
  attr :body_class, :string, default: ""

  attr :rest, :global, include: [:js]

  slot :header, doc: "Title row content rendered beside the mandatory close button."
  slot :inner_block, required: true
  slot :footer, doc: "Footer action row — typically Cancel / Save buttons."

  def drawer(assigns) do
    assigns =
      assigns
      |> assign(:resolved_title_id, resolve_title_id(assigns))
      |> assign(:panel_placement_class, panel_placement_class(assigns.placement))
      |> assign(:panel_size_class, panel_size_class(assigns.size))
      |> assign(:body_padding_class, body_padding_class(assigns.padding))
      |> assign(:header?, assigns.header != [])

    ~H"""
    <div
      :if={@is_open}
      id={@id}
      class="zaq-drawer-overlay"
      phx-hook="DialogOverlay"
      data-return-focus-id={@return_focus_id}
      phx-window-keydown={@on_close}
      phx-key="Escape"
      {@rest}
    >
      <div class={@backdrop_class} phx-click={@on_close} aria-hidden="true"></div>
      <div
        data-drawer-panel
        role="dialog"
        aria-modal="true"
        aria-labelledby={if(@header?, do: @resolved_title_id, else: nil)}
        aria-label={if(@header?, do: nil, else: "Drawer")}
        tabindex="-1"
        class={[
          "zaq-drawer-panel",
          @panel_placement_class,
          @panel_size_class,
          @panel_class
        ]}
      >
        <div class="zaq-drawer-header">
          <div :if={@header?} class="zaq-drawer-header-content">
            {render_slot(@header)}
          </div>
          <div :if={not @header?} class="zaq-drawer-header-content"></div>
          <div class="zaq-drawer-header-actions">
            <DSButton.button
              variant={:secondary}
              icon="hero-x-mark"
              icon_only
              aria-label="Close drawer"
              phx-click={@on_close}
            />
          </div>
        </div>

        <div class={["zaq-drawer-body", @body_padding_class, @body_class]}>
          {render_slot(@inner_block)}
        </div>

        <div :if={@footer != []} class="zaq-drawer-footer">
          <div class="zaq-drawer-footer-actions">
            {render_slot(@footer)}
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :is_open, :boolean, required: true
  attr :on_close, :any, required: true
  attr :title, :string, required: true
  attr :placement, :atom, default: :right, values: [:left, :right, :top, :bottom]
  attr :size, :atom, default: :two_thirds, values: [:one_third, :two_thirds]
  attr :padding, :atom, default: :default, values: [:default, :flush]
  attr :return_focus_id, :string, default: nil
  attr :panel_class, :string, default: ""
  attr :body_class, :string, default: ""

  attr :rest, :global, include: [:js]

  slot :inner_block, required: true
  slot :actions, doc: "Footer actions — pass `DesignSystem.Button` components."

  def form_drawer(assigns) do
    title_id = form_drawer_title_id(assigns.id)

    assigns =
      assigns
      |> assign(:title_id, title_id)
      |> assign(:header_title_id, title_id)

    ~H"""
    <.drawer
      id={@id}
      is_open={@is_open}
      on_close={@on_close}
      placement={@placement}
      size={@size}
      padding={@padding}
      return_focus_id={@return_focus_id}
      title_id={@title_id}
      panel_class={@panel_class}
      body_class={@body_class}
      {@rest}
    >
      <:header>
        <h3
          id={@header_title_id}
          class="zaq-text-h3"
          style="color: var(--zaq-text-color-body-default)"
        >
          {@title}
        </h3>
      </:header>

      {render_slot(@inner_block)}

      <:footer :if={@actions != []}>
        {render_slot(@actions)}
      </:footer>
    </.drawer>
    """
  end

  defp resolve_title_id(%{title_id: id}) when is_binary(id) and id != "", do: id
  defp resolve_title_id(%{header: [%{} | _], id: id}), do: "#{id}-title"
  defp resolve_title_id(%{id: id}), do: "#{id}-title"

  defp form_drawer_title_id(id), do: "#{id}-title"

  defp panel_placement_class(:left), do: "zaq-drawer--left"
  defp panel_placement_class(:right), do: "zaq-drawer--right"
  defp panel_placement_class(:top), do: "zaq-drawer--top"
  defp panel_placement_class(:bottom), do: "zaq-drawer--bottom"

  defp panel_size_class(:one_third), do: "zaq-drawer--size-one-third"
  defp panel_size_class(:two_thirds), do: "zaq-drawer--size-two-thirds"

  defp body_padding_class(:default), do: "zaq-drawer-body--padded"
  defp body_padding_class(:flush), do: "zaq-drawer-body--flush"
end
