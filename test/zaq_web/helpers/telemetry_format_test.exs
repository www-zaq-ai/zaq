defmodule ZaqWeb.Helpers.TelemetryFormatTest do
  use ExUnit.Case, async: true

  alias ZaqWeb.Helpers.TelemetryFormat

  describe "format_value/1" do
    test "formats fallback values with to_string/1" do
      assert TelemetryFormat.format_value(:ready) == "ready"
      assert TelemetryFormat.format_value("already formatted") == "already formatted"
    end
  end

  describe "format_trend_percent/1" do
    test "formats negative trends without a leading plus sign" do
      assert TelemetryFormat.format_trend_percent(-4.2) == "-4.2%"
      assert TelemetryFormat.format_trend_percent(-4.235) == "-4.24%"
    end
  end
end
