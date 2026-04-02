defmodule ZaqWeb.Helpers.DateFormatTest do
  use ExUnit.Case, async: true

  alias ZaqWeb.Helpers.DateFormat

  describe "format_date/1" do
    test "returns dash for nil" do
      assert DateFormat.format_date(nil) == "—"
    end

    test "formats valid iso8601 string" do
      assert DateFormat.format_date("2026-03-13T14:05:00Z") == "March 13, 2026"
    end

    test "returns raw input when iso8601 string is invalid" do
      assert DateFormat.format_date("not-a-date") == "not-a-date"
    end

    test "formats DateTime and NaiveDateTime" do
      assert DateFormat.format_date(~U[2026-03-13 14:05:00Z]) == "March 13, 2026"
      assert DateFormat.format_date(~N[2026-03-13 14:05:00]) == "March 13, 2026"
    end
  end

  describe "format_datetime/1" do
    test "returns dash for nil" do
      assert DateFormat.format_datetime(nil) == "—"
    end

    test "formats DateTime and NaiveDateTime" do
      assert DateFormat.format_datetime(~U[2026-03-13 14:05:00Z]) == "2026-03-13 14:05"
      assert DateFormat.format_datetime(~N[2026-03-13 14:05:00]) == "2026-03-13 14:05"
    end
  end

  describe "format_time/1" do
    test "returns dash for nil" do
      assert DateFormat.format_time(nil) == "—"
    end

    test "formats DateTime and NaiveDateTime" do
      assert DateFormat.format_time(~U[2026-03-13 14:05:00Z]) == "14:05"
      assert DateFormat.format_time(~N[2026-03-13 14:05:00]) == "14:05"
    end
  end
end
