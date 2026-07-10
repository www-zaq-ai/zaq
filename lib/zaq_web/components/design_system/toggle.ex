defmodule ZaqWeb.Components.DesignSystem.Toggle do
  @moduledoc """
  Segmented control for switching between two or more choices.

  Each choice is a map with:

  * `value` (required) — sent as `phx-value-<value_param>` on click
  * `label` (optional) — visible text
  * `icon` (optional) — Heroicon name (e.g. `"hero-bars-3"`)
  * `title` (optional) — tooltip; for icon-only choices also used as `aria-label`

  At least one of `label` or `icon` must be set per choice. Combine both for text+icon segments.

  **Styles:** universal block in `assets/css/styles.css` — `.zaq-toggle-*`,
  plus shared `.zaq-icon-sm` (not under the ingestion-only section).
  """

  use Phoenix.Component

  import ZaqWeb.CoreComponents, only: [icon: 1]

  attr :value, :string, required: true, doc: "Currently selected choice `value`."

  attr :choices, :list,
    required: true,
    doc: "Non-empty list of choice maps (`value`, optional `label` / `icon` / `title`)."

  attr :event, :string,
    required: true,
    doc: "LiveView `phx-click` event fired when a segment is selected."

  attr :value_param, :string,
    default: "value",
    doc: "Suffix for `phx-value-*` on each segment button."

  attr :variant, :atom, default: :default, values: [:default, :pill]

  attr :suffix, :string,
    default: nil,
    doc: "Optional caption after the toggle group (e.g. item count)."

  attr :class, :any, default: nil

  def toggle(assigns) do
    ~H"""
    <div class={["zaq-toggle-row", @class]}>
      <div class={toggle_group_class(@variant)}>
        <button
          :for={choice <- @choices}
          type="button"
          phx-click={@event}
          {choice_value_attrs(@value_param, choice)}
          class={segment_class(@value, choice)}
          title={choice_title(choice)}
          aria-label={segment_aria_label(choice)}
          aria-pressed={to_string(@value == choice.value)}
        >
          <.icon :if={choice[:icon]} name={choice.icon} class="zaq-icon-sm" />
          <span :if={choice[:label]} class="zaq-toggle-segment-label">
            {choice.label}
          </span>
        </button>
      </div>
      <span :if={@suffix} class="zaq-text-caption zaq-toggle-count">
        {@suffix}
      </span>
    </div>
    """
  end

  defp toggle_group_class(:pill), do: "zaq-toggle-group zaq-toggle-group-pill"
  defp toggle_group_class(_), do: "zaq-toggle-group"

  defp segment_class(selected, choice) do
    [
      "zaq-toggle-segment zaq-text-body",
      choice[:label] && choice[:icon] && "zaq-toggle-segment--with-label",
      choice[:label] && !choice[:icon] && "zaq-toggle-segment--text-only",
      selected == choice.value && "zaq-toggle-segment--active"
    ]
  end

  defp choice_title(%{title: title}) when is_binary(title) and title != "", do: title
  defp choice_title(%{label: label}) when is_binary(label) and label != "", do: label
  defp choice_title(_), do: nil

  defp segment_aria_label(choice) do
    icon = Map.get(choice, :icon)
    label = Map.get(choice, :label)

    if is_binary(icon) and icon != "" and (is_nil(label) or label == "") do
      choice_title(choice)
    end
  end

  defp choice_value_attrs(value_param, choice) do
    %{"phx-value-#{value_param}" => choice.value}
  end
end
