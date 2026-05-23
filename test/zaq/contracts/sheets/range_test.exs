defmodule Zaq.Contracts.Sheets.RangeTest do
  use ExUnit.Case, async: true

  alias Zaq.Contracts.Sheets.Range

  describe "normalize/1" do
    test "trims whitespace and returns non-empty" do
      assert Range.normalize("  Sheet1!A1:B2  ") == "Sheet1!A1:B2"
    end

    test "returns nil when empty after trim" do
      assert Range.normalize("   ") == nil
      assert Range.normalize("\n\t  ") == nil
    end

    test "returns nil for non-binary values" do
      assert Range.normalize(nil) == nil
      assert Range.normalize(123) == nil
      assert Range.normalize(:atom) == nil
      assert Range.normalize(%{}) == nil
    end
  end

  describe "valid_a1?/1" do
    test "returns true for valid trimmed inputs" do
      assert Range.valid_a1?("Sheet1!A1")
      assert Range.valid_a1?("  Sheet1!A1:B2  ")
    end

    test "returns false for invalid binaries" do
      refute Range.valid_a1?("Sheet1A1")
      refute Range.valid_a1?("Sheet1!a1")
      refute Range.valid_a1?("Sheet1!1A")
      refute Range.valid_a1?("Sheet1!A")
    end

    test "returns false for non-binary values" do
      refute Range.valid_a1?(nil)
      refute Range.valid_a1?(42)
      refute Range.valid_a1?(:sheet)
      refute Range.valid_a1?(["Sheet1!A1"])
    end
  end
end
