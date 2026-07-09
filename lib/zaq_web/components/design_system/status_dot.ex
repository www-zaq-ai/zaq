defmodule ZaqWeb.Components.DesignSystem.StatusDot do
  @moduledoc """
  Inline status indicator dot for BO surfaces.

  **Variations:** `:active` (green), `:inactive` (red), and optional `count` for
  notification-style counters (display caps at `+99`).

  **Styles:** `assets/css/styles.css` — `.zaq-status-dot*`.
  """

  use Phoenix.Component

  attr :status, :atom, required: true, values: [:active, :inactive]

  attr :count, :integer,
    default: nil,
    doc: "When set and greater than zero, renders a counter badge beside the dot."

  attr :class, :any, default: nil
  attr :rest, :global, include: ~w(data-testid aria-label)

  def status_dot(assigns) do
    show_count = show_count?(assigns.count)

    assigns =
      assigns
      |> assign(:show_count, show_count)
      |> assign(:count_label, if(show_count, do: format_count(assigns.count), else: nil))
      |> assign(:dot_class, status_dot_class(assigns.status))

    ~H"""
    <span :if={@show_count} class={["zaq-status-dot-group", @class]} {@rest}>
      <span class={["zaq-status-dot", @dot_class]} aria-hidden="true" />
      <span class="zaq-status-dot-count zaq-text-caption">{@count_label}</span>
    </span>
    <span
      :if={!@show_count}
      class={["zaq-status-dot", @dot_class, @class]}
      {@rest}
    />
    """
  end

  @doc false
  def format_count(count) when is_integer(count) and count > 99, do: "+99"
  def format_count(count) when is_integer(count), do: Integer.to_string(count)

  defp status_dot_class(:active), do: "zaq-status-dot--active"
  defp status_dot_class(:inactive), do: "zaq-status-dot--inactive"

  defp show_count?(count) when is_integer(count) and count > 0, do: true
  defp show_count?(_), do: false
end
