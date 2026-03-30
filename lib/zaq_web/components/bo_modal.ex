defmodule ZaqWeb.Components.BOModal do
  @moduledoc """
  Reusable Back Office modal primitives.
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
end
