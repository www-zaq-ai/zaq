defmodule ZaqWeb.Components.BOModal do
  @moduledoc """
  Reusable Back Office modal primitives.

  - `modal_shell/1` is a low-level wrapper.
  - `form_dialog/1` is the default for BO add/edit dialogs and enforces viewport-safe
    max height with internal scrolling.
  """

  use ZaqWeb, :html

  attr :id, :string, default: nil
  attr :cancel_event, :string, required: true
  attr :max_width_class, :string, default: "max-w-sm"
  attr :panel_class, :string, default: ""
  attr :rest, :global
  slot :inner_block, required: true

  def modal_shell(assigns) do
    ~H"""
    <div
      id={@id}
      class="fixed inset-0 z-50 flex items-center justify-center p-4"
      phx-window-keydown={@cancel_event}
      phx-key="Escape"
      {@rest}
    >
      <div class="absolute inset-0 bg-black/40 backdrop-blur-sm" phx-click={@cancel_event}></div>
      <div class={[
        "relative w-full rounded-2xl border border-black/10 bg-white p-8 shadow-2xl",
        @max_width_class,
        @panel_class
      ]}>
        {render_slot(@inner_block)}
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
  attr :max_width_class, :string, default: "max-w-sm"
  attr :confirm_button_id, :string, default: nil
  attr :confirm_value_id, :string, default: nil

  def confirm_dialog(assigns) do
    ~H"""
    <.modal_shell
      id={@id}
      cancel_event={@cancel_event}
      max_width_class={@max_width_class}
      panel_class="text-center"
    >
      <div class="mx-auto mb-4 grid h-10 w-10 place-items-center rounded-lg bg-red-100">
        <.icon name="hero-trash" class="h-5 w-5 text-red-500" />
      </div>
      <h3 class="mb-2 font-mono text-base font-bold text-black">{@title}</h3>
      <p class="mb-6 font-mono text-[0.75rem] text-black/40">{@message}</p>
      <div class="flex items-center justify-center gap-3">
        <button
          phx-click={@cancel_event}
          class="rounded-xl border border-black/10 px-5 py-2.5 font-mono text-[0.75rem] text-black/40 transition-all hover:border-black/20 hover:text-black"
        >
          {@cancel_label}
        </button>
        <button
          id={@confirm_button_id}
          phx-click={@confirm_event}
          phx-value-id={@confirm_value_id}
          class="rounded-xl bg-red-500 px-5 py-2.5 font-mono text-[0.75rem] font-bold text-white transition-all hover:bg-red-600"
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
  attr :max_width_class, :string, default: "max-w-3xl"
  attr :panel_class, :string, default: ""
  attr :body_class, :string, default: ""
  attr :rest, :global
  slot :inner_block, required: true
  slot :actions

  def form_dialog(assigns) do
    ~H"""
    <div
      id={@id}
      class="fixed inset-0 z-50 flex items-center justify-center p-4"
      phx-window-keydown={@cancel_event}
      phx-key="Escape"
      {@rest}
    >
      <div class="absolute inset-0 bg-black/40 backdrop-blur-sm" phx-click={@cancel_event}></div>
      <div class={[
        "relative w-full rounded-2xl border border-black/10 bg-white shadow-2xl max-h-[90vh] overflow-hidden flex flex-col",
        @max_width_class,
        @panel_class
      ]}>
        <div class="shrink-0 border-b border-black/[0.08] px-6 py-5">
          <h3 class="font-mono text-[0.95rem] font-bold text-black">{@title}</h3>
          <button
            type="button"
            phx-click={@cancel_event}
            aria-label="Close dialog"
            class="absolute right-4 top-4 inline-flex h-9 w-9 items-center justify-center rounded-lg border border-black/10 text-black/50 hover:bg-black/[0.04] hover:text-black/70"
          >
            <.icon name="hero-x-mark" class="h-4 w-4" />
          </button>
        </div>

        <div class={["min-h-0 flex-1 overflow-y-auto px-6 py-5", @body_class]}>
          {render_slot(@inner_block)}
        </div>

        <div :if={@actions != []} class="shrink-0 border-t border-black/[0.08] bg-white px-6 py-4">
          <div class="flex items-center justify-end gap-3">
            {render_slot(@actions)}
          </div>
        </div>
      </div>
    </div>
    """
  end
end
