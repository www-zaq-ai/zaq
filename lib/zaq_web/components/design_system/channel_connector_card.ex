defmodule ZaqWeb.Components.DesignSystem.ChannelConnectorCard do
  @moduledoc """
  Connector settings bar shared by channel configuration pages.

  The parent LiveView owns selection and action events. Pass its existing buttons
  through `:actions` so their IDs and event contracts remain unchanged.
  """

  use Phoenix.Component

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :provider, :string, required: true
  attr :url, :string, default: nil
  attr :enabled, :boolean, default: false
  attr :selected, :boolean, default: false
  attr :select_event, :string, default: nil
  attr :connector_id, :integer, default: nil

  slot :status
  slot :detail
  slot :actions

  def channel_connector_card(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "bg-white rounded-xl border p-5 flex items-center justify-between",
        if(@selected, do: "border-[var(--zaq-border-color-accent)]", else: "border-black/10")
      ]}
    >
      <div class="flex items-center gap-4">
        <div class={[
          "w-10 h-10 rounded-xl grid place-items-center",
          if(@enabled, do: "bg-[#0058CC]/10", else: "bg-black/5")
        ]}>
          <svg
            class={if(@enabled, do: "w-5 h-5 text-[#0058CC]", else: "w-5 h-5 text-black/30")}
            fill="none"
            stroke="currentColor"
            stroke-width="1.8"
            viewBox="0 0 24 24"
            aria-hidden="true"
          >
            <path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z" />
          </svg>
        </div>
        <div>
          <div class="flex items-center gap-2 mb-1">
            <button
              :if={@select_event}
              type="button"
              phx-click={@select_event}
              phx-value-id={@connector_id}
              aria-current={if(@selected, do: "true", else: nil)}
              class="font-mono text-sm font-bold text-black zaq-focus-visible"
            >
              {@name}
            </button>
            <p :if={!@select_event} class="font-mono text-sm font-bold text-black">{@name}</p>
            {render_slot(@status)}
            <span class={[
              "font-mono text-[0.6rem] px-2 py-0.5 rounded-full uppercase tracking-wider",
              if(@enabled,
                do: "bg-emerald-100 text-emerald-700",
                else: "bg-black/5 text-black/30"
              )
            ]}>
              {if @enabled, do: "Active", else: "Disabled"}
            </span>
          </div>
          <div class="flex items-center gap-3">
            <p class="font-mono text-[0.7rem] text-black/40">{@provider}</p>
            <span :if={@url} class="text-black/10">·</span>
            <p :if={@url} class="font-mono text-[0.7rem] text-black/30 truncate max-w-[280px]">
              {@url}
            </p>
          </div>
          {render_slot(@detail)}
        </div>
      </div>
      <div class="flex items-center gap-2">{render_slot(@actions)}</div>
    </div>
    """
  end
end
