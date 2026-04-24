defmodule ZaqWeb.Components.SearchableSelect do
  @moduledoc """
  Searchable select component used in BO forms.

  Supports client-side filtering and optional creation flow integration through
  a LiveView event hook.
  """
  use Phoenix.Component

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :value, :any, default: nil
  attr :options, :list, default: []
  attr :placeholder, :string, default: "Search..."
  attr :empty_label, :string, default: "Select..."
  attr :allow_create, :boolean, default: false
  attr :on_create_event, :string, default: "create_and_assign_team"
  attr :on_search, :string, default: nil
  attr :compact, :boolean, default: false

  @doc "Renders a searchable select dropdown with optional create action."
  def searchable_select(assigns) do
    ~H"""
    <div id={@id} phx-hook="SearchableSelect" data-server-search={@on_search} class="relative">
      <input type="hidden" name={@name} value={@value} data-select-value />
      <button
        type="button"
        data-select-trigger
        class={[
          "w-full flex items-center justify-between font-mono text-black border border-black/10 rounded-xl px-4 bg-[#fafafa] focus:outline-none focus:ring-2 focus:ring-[#03b6d4]/20 focus:border-[#03b6d4] transition-all",
          if(@compact, do: "h-8 text-[0.72rem] rounded-lg", else: "h-11 text-[0.88rem]")
        ]}
      >
        <span data-select-label>
          {Enum.find_value(@options, @empty_label, fn {label, val} ->
            if to_string(val) == to_string(@value || ""), do: label
          end)}
        </span>
        <svg
          class="w-4 h-4 shrink-0 text-black/30"
          fill="none"
          stroke="currentColor"
          viewBox="0 0 24 24"
        >
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 9l-7 7-7-7" />
        </svg>
      </button>
      <div
        data-select-panel
        class="hidden absolute z-50 w-full bg-white border border-black/10 rounded-xl shadow-lg mt-1 overflow-hidden"
      >
        <div class="p-2 border-b border-black/[0.06]">
          <input
            type="text"
            data-select-search
            placeholder={@placeholder}
            class="w-full font-mono text-[0.82rem] text-black border border-black/10 rounded-lg h-9 px-3 bg-[#fafafa] placeholder:text-black/25 focus:outline-none focus:ring-2 focus:ring-[#03b6d4]/20 focus:border-[#03b6d4] transition-all"
          />
        </div>
        <ul data-select-list class="max-h-52 overflow-y-auto py-1">
          <li
            :for={{label, value} <- @options}
            data-select-option={label}
            data-select-value={value}
            class="font-mono text-[0.82rem] text-black px-4 py-2 cursor-pointer hover:bg-[#03b6d4]/10 transition-colors"
          >
            {label}
          </li>
        </ul>
        <button
          :if={@allow_create}
          type="button"
          data-select-create
          data-create-event={@on_create_event}
          class="hidden w-full text-left font-mono text-[0.82rem] px-4 py-2.5 text-[#03b6d4] hover:bg-[#03b6d4]/10 transition-colors border-t border-black/[0.06]"
        >
          <span data-create-label></span>
        </button>
      </div>
    </div>
    """
  end
end
