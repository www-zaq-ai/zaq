defmodule ZaqWeb.Helpers.MetricsHelpers do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]

  @doc "Handles the `set_range` event shared across metrics LiveViews."
  def handle_set_range(ranges, range, socket, assign_fn) do
    next_range = if range in ranges, do: range, else: socket.assigns.range
    {:noreply, socket |> assign(:range, next_range) |> assign_fn.()}
  end

  @doc "Returns time-bucket labels for a given range key."
  def labels_for_range("24h"), do: ["00:00", "04:00", "08:00", "12:00", "16:00", "20:00"]
  def labels_for_range("7d"), do: ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
  def labels_for_range("30d"), do: Enum.map(0..9, fn idx -> "D#{idx * 3 + 1}" end)
  def labels_for_range("90d"), do: Enum.map(1..12, fn idx -> "W#{idx}" end)
  def labels_for_range(_), do: labels_for_range("7d")
end
