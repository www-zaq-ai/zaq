defmodule ZaqWeb.Components.SearchableSelect do
  @moduledoc false
  use Phoenix.Component

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :value, :any, default: nil
  attr :options, :list, default: []
  attr :placeholder, :string, default: "Search..."
  attr :empty_label, :string, default: "Select..."

  def searchable_select(assigns) do
    ~H"""
    <div id={@id} phx-hook="SearchableSelect" class="relative">
      <input type="hidden" name={@name} value={@value} data-select-value />
      <button
        type="button"
        data-select-trigger
        class="w-full flex items-center justify-between font-mono text-[0.88rem] text-black border border-black/10 rounded-xl h-11 px-4 bg-[#fafafa] focus:outline-none focus:ring-2 focus:ring-[#03b6d4]/20 focus:border-[#03b6d4] transition-all"
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
      </div>
    </div>
    """
  end
end
