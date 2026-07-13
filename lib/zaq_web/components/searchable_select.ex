defmodule ZaqWeb.Components.SearchableSelect do
  @moduledoc """
  Searchable select component used in BO forms.

  Supports client-side filtering and optional creation flow integration through
  a LiveView event hook.

  Pass `label` to render an external uppercase label (`.zaq-field-label-uppercase`).
  Use `label_position` to place it `inline` (default) or `block` (above the control).
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
  attr :searchable, :boolean, default: true
  attr :label, :string, default: nil
  attr :label_position, :string, default: "inline"

  @doc "Renders a searchable select dropdown with optional create action."
  def searchable_select(assigns) do
    assigns =
      assigns
      |> assign(:inner, inner_markup(assigns))
      |> assign(:show_label?, present_label?(assigns.label))
      |> assign(:block_label?, block_label?(assigns.label_position))

    ~H"""
    <%= if @show_label? do %>
      <%= if @block_label? do %>
        <div class="zaq-field-row-block">
          <label for={"#{@id}-trigger"} class="zaq-field-label-uppercase zaq-text-caption">
            {@label}
          </label>
          {@inner}
        </div>
      <% else %>
        <div class="zaq-field-row-inline">
          <label for={"#{@id}-trigger"} class="zaq-field-label-uppercase zaq-text-caption">
            {@label}
          </label>
          <div class="zaq-field-row-inline-control">
            {@inner}
          </div>
        </div>
      <% end %>
    <% else %>
      {@inner}
    <% end %>
    """
  end

  defp present_label?(nil), do: false

  defp present_label?(s) when is_binary(s) do
    s |> String.trim() != ""
  end

  defp present_label?(_), do: false

  defp block_label?("block"), do: true
  defp block_label?(_), do: false

  defp inner_markup(assigns) do
    ~H"""
    <div id={@id} phx-hook="SearchableSelect" data-server-search={@on_search} class="relative">
      <input type="hidden" name={@name} value={@value} data-select-value />
      <button
        type="button"
        id={"#{@id}-trigger"}
        data-select-trigger
        class={[
          "zaq-control-combobox-trigger transition-colors",
          if(@compact, do: "zaq-control-combobox-trigger--compact")
        ]}
      >
        <span
          data-select-label
          class={@compact && "zaq-text-body-sm truncate min-w-0"}
        >
          {Enum.find_value(@options, @empty_label, fn option ->
            {label, val, _suffix, _disabled?} = normalize_option(option)
            if to_string(val) == to_string(@value || ""), do: label
          end)}
        </span>
        <svg
          class="h-4 w-4 shrink-0"
          fill="none"
          stroke="currentColor"
          viewBox="0 0 24 24"
          style="color: var(--zaq-text-color-body-tertiary)"
        >
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 9l-7 7-7-7" />
        </svg>
      </button>
      <div
        data-select-panel
        class="zaq-searchable-select-panel absolute z-50 mt-1 hidden w-full overflow-hidden"
      >
        <div :if={@searchable} class="zaq-searchable-select-search-row">
          <input
            type="text"
            data-select-search
            placeholder={@placeholder}
            class={[
              "zaq-control-text w-full transition-colors zaq-text-body-sm",
              if(@compact, do: "zaq-control-text--compact")
            ]}
          />
        </div>
        <ul data-select-list class="max-h-52 overflow-y-auto">
          <li
            :for={{label, value, suffix, disabled?} <- Enum.map(@options, &normalize_option/1)}
            data-select-option={label}
            data-select-value={value}
            data-select-disabled={if disabled?, do: "true", else: "false"}
            class={[
              "zaq-dropdown-menu-item zaq-dropdown-menu-item--padded",
              disabled? && "opacity-50 cursor-not-allowed"
            ]}
          >
            {label}
            <em :if={suffix} class="text-black/35 font-normal">{suffix}</em>
          </li>
        </ul>
        <button
          :if={@allow_create}
          type="button"
          data-select-create
          data-create-event={@on_create_event}
          class="zaq-text-body-sm zaq-searchable-select-create hidden"
        >
          <span data-create-label></span>
        </button>
      </div>
    </div>
    """
  end

  defp normalize_option({label, value, suffix, disabled?}), do: {label, value, suffix, disabled?}
  defp normalize_option({label, value, suffix}), do: {label, value, suffix, false}
  defp normalize_option({label, value}), do: {label, value, nil, false}
end
