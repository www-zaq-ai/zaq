defmodule ZaqWeb.Helpers.MetricsHelpersTest do
  use ExUnit.Case, async: true

  alias ZaqWeb.Helpers.MetricsHelpers

  defp build_socket(initial_range) do
    %Phoenix.LiveView.Socket{
      assigns: %{range: initial_range, __changed__: %{}},
      private: %{
        live_temp: %{},
        lifecycle: %Phoenix.LiveView.Lifecycle{}
      }
    }
  end

  describe "handle_set_range/4" do
    test "assigns requested range when it is allowed" do
      socket = build_socket("7d")
      ranges = ["24h", "7d", "30d", "90d"]

      assert {:noreply, updated} =
               MetricsHelpers.handle_set_range(ranges, "24h", socket, fn s ->
                 Phoenix.Component.assign(s, :refreshed?, true)
               end)

      assert updated.assigns.range == "24h"
      assert updated.assigns.refreshed?
    end

    test "keeps previous range when requested range is invalid" do
      socket = build_socket("30d")

      assert {:noreply, updated} =
               MetricsHelpers.handle_set_range(["24h", "7d"], "bad", socket, fn s ->
                 Phoenix.Component.assign(s, :refreshed?, true)
               end)

      assert updated.assigns.range == "30d"
      assert updated.assigns.refreshed?
    end
  end

  describe "labels_for_range/1" do
    test "returns labels for known ranges" do
      assert MetricsHelpers.labels_for_range("24h") ==
               ["00:00", "04:00", "08:00", "12:00", "16:00", "20:00"]

      assert MetricsHelpers.labels_for_range("7d") ==
               ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

      assert MetricsHelpers.labels_for_range("30d") ==
               ["D1", "D4", "D7", "D10", "D13", "D16", "D19", "D22", "D25", "D28"]

      assert MetricsHelpers.labels_for_range("90d") ==
               ["W1", "W2", "W3", "W4", "W5", "W6", "W7", "W8", "W9", "W10", "W11", "W12"]
    end

    test "falls back to 7d labels for unknown ranges" do
      assert MetricsHelpers.labels_for_range("unknown") ==
               ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    end
  end
end
