defmodule ZaqWeb.Components.BOModal do
  @moduledoc """
  Reusable Back Office modal primitives.

  - `modal_shell/1` is a low-level wrapper — defaults use `modal.css` (`zaq-bo-modal-backdrop`,
    `zaq-modal`). Pass optional `title` for the shared `.zaq-modal-header` row (same chrome as
    `form_dialog/1` and `iframe_dialog/1`). Override `panel_base_class` only for exceptions; use
    `panel_base_class="zaq-modal zaq-modal--flush"` when inner chrome provides its own padding.
  - `form_dialog/1` is the default for BO add/edit dialogs and enforces viewport-safe
    max height with internal scrolling. Pass `DesignSystem.Button` components in the `:actions` slot.
  """

  use ZaqWeb, :html

  alias ZaqWeb.Components.DesignSystem.Button, as: DSButton

  attr :id, :string, default: nil
  attr :cancel_event, :string, required: true
  attr :title, :string, default: nil
  attr :title_id, :string, default: nil
  attr :max_width_class, :string, default: "zaq-modal--width-sm"
  attr :panel_class, :string, default: ""
  attr :backdrop_class, :string, default: "zaq-bo-modal-backdrop"
  attr :panel_base_class, :string, default: "zaq-modal"

  attr :rest, :global
  slot :inner_block, required: true
  slot :header_actions, doc: "Optional controls before the close button when `title` is set."

  def modal_shell(assigns) do
    titled? = titled?(assigns.title)

    assigns =
      assigns
      |> assign(:titled?, titled?)
      |> then(fn a -> assign(a, :title_id, resolve_title_id(a)) end)
      |> then(fn a -> assign(a, :resolved_panel_base_class, resolve_panel_base_class(a)) end)

    ~H"""
    <div
      id={@id}
      class="zaq-bo-modal-overlay"
      phx-window-keydown={@cancel_event}
      phx-key="Escape"
      {@rest}
    >
      <div class={@backdrop_class} phx-click={@cancel_event}></div>
      <div class={[
        @resolved_panel_base_class,
        @max_width_class,
        @panel_class
      ]}>
        <%= if @titled? do %>
          <.modal_header
            title={@title}
            title_id={@title_id}
            cancel_event={@cancel_event}
          >
            <:actions :if={@header_actions != []}>
              {render_slot(@header_actions)}
            </:actions>
          </.modal_header>
          <div class="zaq-modal-body">
            {render_slot(@inner_block)}
          </div>
        <% else %>
          {render_slot(@inner_block)}
        <% end %>
      </div>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :title_id, :string, default: nil
  attr :cancel_event, :string, required: true

  slot :actions, doc: "Optional controls rendered before the close button."

  def modal_header(assigns) do
    ~H"""
    <div class="zaq-modal-header">
      <h3
        id={@title_id}
        class="zaq-text-h3"
        style="color: var(--zaq-text-color-body-default)"
      >
        {@title}
      </h3>
      <div class="zaq-modal-header-actions">
        {render_slot(@actions)}
        <DSButton.button
          variant={:secondary}
          icon="hero-x-mark"
          icon_only
          aria-label="Close dialog"
          phx-click={@cancel_event}
        />
      </div>
    </div>
    """
  end

  attr :id, :string, default: nil
  attr :cancel_event, :string, default: "cancel_delete"
  attr :confirm_event, :string, default: "delete"
  attr :title, :string, required: true
  attr :message, :string, required: true
  attr :confirm_label, :string, default: "Delete"
  attr :cancel_label, :string, default: "Cancel"
  attr :max_width_class, :string, default: "zaq-modal--width-sm"
  attr :confirm_button_id, :string, default: nil
  attr :confirm_value_id, :string, default: nil

  def confirm_dialog(assigns) do
    ~H"""
    <.modal_shell
      id={@id}
      cancel_event={@cancel_event}
      max_width_class={@max_width_class}
      panel_class="zaq-modal--centered"
    >
      <div class="zaq-modal-confirm-icon-badge">
        <.icon name="hero-trash" class="zaq-icon-md" />
      </div>
      <div class="zaq-layout-stack-tight zaq-modal-confirm-copy">
        <h3 class="zaq-text-h3" style="color: var(--zaq-text-color-body-default)">{@title}</h3>
        <p class="zaq-text-body-sm" style="color: var(--zaq-text-color-body-tertiary)">
          {@message}
        </p>
      </div>
      <div class="zaq-modal-confirm-actions">
        <button
          type="button"
          phx-click={@cancel_event}
          class="zaq-btn zaq-btn-secondary zaq-btn-text_label-default"
        >
          {@cancel_label}
        </button>
        <button
          type="button"
          id={@confirm_button_id}
          phx-click={@confirm_event}
          phx-value-id={@confirm_value_id}
          class="zaq-btn zaq-btn-tertiary zaq-btn-danger zaq-btn-text_label-default"
        >
          {@confirm_label}
        </button>
      </div>
    </.modal_shell>
    """
  end

  attr :id, :string, default: nil
  attr :cancel_event, :string, required: true
  attr :title, :string, required: true
  attr :max_width_class, :string, default: "zaq-modal--width-3xl"
  attr :panel_class, :string, default: ""
  attr :body_class, :string, default: ""
  attr :rest, :global
  slot :inner_block, required: true
  slot :actions

  def form_dialog(assigns) do
    assigns = assign(assigns, :form_dialog_title_id, form_dialog_title_id(assigns.id))

    ~H"""
    <.modal_shell
      id={@id}
      cancel_event={@cancel_event}
      max_width_class={@max_width_class}
      panel_base_class="zaq-modal zaq-modal--flush zaq-modal--form"
      panel_class={@panel_class}
      role="dialog"
      aria-modal="true"
      aria-labelledby={@form_dialog_title_id}
      aria-label={if(@form_dialog_title_id, do: nil, else: @title)}
      {@rest}
    >
      <.modal_header
        title={@title}
        title_id={@form_dialog_title_id}
        cancel_event={@cancel_event}
      />

      <div class={["zaq-modal-body", @body_class]}>
        {render_slot(@inner_block)}
      </div>

      <div :if={@actions != []} class="zaq-modal-form-footer">
        <div class="zaq-modal-form-actions">
          {render_slot(@actions)}
        </div>
      </div>
    </.modal_shell>
    """
  end

  attr :id, :string, default: nil
  attr :cancel_event, :string, required: true
  attr :title, :string, required: true
  attr :src, :string, required: true
  attr :max_width_class, :string, default: "zaq-modal--width-4xl"
  attr :height_class, :string, default: ""

  def iframe_dialog(assigns) do
    ~H"""
    <.modal_shell
      id={@id}
      cancel_event={@cancel_event}
      max_width_class={@max_width_class}
      panel_base_class="zaq-modal zaq-modal--flush zaq-modal--form"
    >
      <.modal_header title={@title} cancel_event={@cancel_event} />
      <iframe src={@src} class={["zaq-modal-iframe", @height_class]}></iframe>
    </.modal_shell>
    """
  end

  defp titled?(title) when is_binary(title), do: title != ""
  defp titled?(_), do: false

  defp resolve_title_id(%{title_id: id}) when is_binary(id) and id != "", do: id
  defp resolve_title_id(%{id: id}) when is_binary(id), do: "#{id}-title"
  defp resolve_title_id(_), do: nil

  defp resolve_panel_base_class(%{titled?: true, panel_base_class: "zaq-modal"}),
    do: "zaq-modal zaq-modal--flush zaq-modal--form"

  defp resolve_panel_base_class(%{titled?: true, panel_base_class: base}),
    do: ensure_form_layout(base)

  defp resolve_panel_base_class(%{panel_base_class: base}), do: base

  defp ensure_form_layout(base) do
    if String.contains?(base, "zaq-modal--form"),
      do: base,
      else: String.trim(base <> " zaq-modal--form")
  end

  defp form_dialog_title_id(nil), do: nil
  defp form_dialog_title_id(id) when is_binary(id), do: "#{id}-title"
end
