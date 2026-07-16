defmodule ZaqWeb.Helpers.TimezoneTest do
  use ExUnit.Case, async: true

  import Zaq.TimezoneTestHelpers

  alias ZaqWeb.Helpers.Timezone

  setup do
    stub_system_timezone()
  end

  describe "shift/1" do
    test "nil returns nil" do
      assert Timezone.shift(nil) == nil
    end

    test "with no configured timezone returns DateTime unchanged" do
      dt = ~U[2026-03-13 14:05:00Z]
      assert Timezone.shift(dt) == dt
    end

    test "shifts by configured GMT+ timezone" do
      stub_system_timezone("GMT+03:00")

      dt = ~U[2026-03-13 14:05:00Z]
      assert Timezone.shift(dt) == ~N[2026-03-13 17:05:00]
    end

    test "shifts by configured GMT- timezone" do
      stub_system_timezone("GMT-05:00")

      dt = ~U[2026-03-13 14:05:00Z]
      assert Timezone.shift(dt) == ~N[2026-03-13 09:05:00]
    end
  end

  describe "offset_to_gmt_string/1" do
    test "UTC offset" do
      assert Timezone.offset_to_gmt_string("0") == "GMT+00:00"
    end

    test "positive offset (west of UTC, JS inverts sign)" do
      assert Timezone.offset_to_gmt_string("180") == "GMT-03:00"
    end

    test "negative offset (east of UTC, JS inverts sign)" do
      assert Timezone.offset_to_gmt_string("-180") == "GMT+03:00"
    end

    test "max positive offset" do
      assert Timezone.offset_to_gmt_string("720") == "GMT-12:00"
    end

    test "max negative offset" do
      assert Timezone.offset_to_gmt_string("-840") == "GMT+14:00"
    end
  end
end
