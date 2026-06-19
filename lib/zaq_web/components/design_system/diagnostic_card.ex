defmodule ZaqWeb.Components.DesignSystem.DiagnosticCard do
  @moduledoc """
  Service / connection card: label, optional connection status chip, rows in the default slot,
  and optional test action (`phx-click` event name handled by the parent LiveView).
  """

  use Phoenix.Component

  import ZaqWeb.Components.DesignSystem.StatusBadge, only: [status_badge: 1]

  attr :label, :string, required: true
  attr :status, :any, default: nil
  attr :event, :string, default: nil
  attr :button_label, :string, default: "Test Connection"
  slot :inner_block, required: true
  slot :footer_extra

  def diagnostic_card(assigns) do
    ~H"""
    <div class="bg-white rounded-xl border border-black/10 p-5 flex flex-col">
      <div class="flex items-center justify-between mb-4">
        <p class="font-mono text-[0.7rem] text-black/40 uppercase tracking-wider">{@label}</p>
        <.status_badge :if={@status != nil} status={@status} />
      </div>
      <div class="space-y-2 mb-4">
        {render_slot(@inner_block)}
      </div>
      <div :if={@event} class="mt-auto border-t border-black/5 pt-3">
        <button
          phx-click={@event}
          disabled={@status == :loading}
          class="w-full font-mono text-[0.75rem] font-bold px-4 py-2 rounded-lg bg-[#3c4b64] text-white hover:bg-[#3c4b64]/80 disabled:opacity-40 transition-colors"
        >
          {if @status == :loading, do: "Testing…", else: @button_label}
        </button>
        <p
          :if={is_tuple(@status) and elem(@status, 0) == :error}
          class="font-mono text-[0.7rem] text-red-500 mt-2 break-all"
        >
          {elem(@status, 1)}
        </p>
        {render_slot(@footer_extra)}
      </div>
    </div>
    """
  end
end
