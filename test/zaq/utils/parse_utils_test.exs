defmodule Zaq.Utils.ParseUtilsTest do
  use ExUnit.Case, async: true

  doctest Zaq.Utils.ParseUtils

  alias Zaq.Utils.ParseUtils

  describe "parse_int/2" do
    test "returns default for nil and empty string" do
      assert ParseUtils.parse_int(nil, 7) == 7
      assert ParseUtils.parse_int("", 7) == 7
    end

    test "returns parsed integer for valid numeric string" do
      assert ParseUtils.parse_int("42", 0) == 42
    end

    test "returns leading parsed integer when input has suffix" do
      assert ParseUtils.parse_int("42abc", 0) == 42
    end

    test "returns default for non-numeric input" do
      assert ParseUtils.parse_int("abc", 9) == 9
    end
  end

  describe "parse_int_strict/1" do
    test "accepts integers and strict integer strings" do
      assert ParseUtils.parse_int_strict(42) == {:ok, 42}
      assert ParseUtils.parse_int_strict("42") == {:ok, 42}
      assert ParseUtils.parse_int_strict("-7") == {:ok, -7}
    end

    test "rejects non-strict strings and non-string terms" do
      assert ParseUtils.parse_int_strict("42abc") == :error
      assert ParseUtils.parse_int_strict("abc") == :error
      assert ParseUtils.parse_int_strict(nil) == :error
      assert ParseUtils.parse_int_strict(%{}) == :error
    end
  end

  describe "parse_optional_int/1" do
    test "returns nil for blank and invalid values" do
      assert ParseUtils.parse_optional_int(nil) == nil
      assert ParseUtils.parse_optional_int("") == nil
      assert ParseUtils.parse_optional_int("42abc") == nil
      assert ParseUtils.parse_optional_int("abc") == nil
      assert ParseUtils.parse_optional_int(%{}) == nil
    end

    test "returns integer for integer and strict integer strings" do
      assert ParseUtils.parse_optional_int(42) == 42
      assert ParseUtils.parse_optional_int("42") == 42
      assert ParseUtils.parse_optional_int("-7") == -7
    end
  end

  describe "parse_optional_int/2" do
    test "returns default for blank and invalid values" do
      assert ParseUtils.parse_optional_int(nil, 7) == 7
      assert ParseUtils.parse_optional_int("", 7) == 7
      assert ParseUtils.parse_optional_int("42abc", 7) == 7
      assert ParseUtils.parse_optional_int("abc", 7) == 7
      assert ParseUtils.parse_optional_int(%{}, 7) == 7
    end

    test "returns parsed integer for integer and strict integer strings" do
      assert ParseUtils.parse_optional_int(42, 7) == 42
      assert ParseUtils.parse_optional_int("42", 7) == 42
      assert ParseUtils.parse_optional_int("-7", 1) == -7
    end
  end

  describe "parse_float/2" do
    test "returns default for nil, blank, and invalid values" do
      assert ParseUtils.parse_float(nil, 1.25) == 1.25
      assert ParseUtils.parse_float("", 1.25) == 1.25
      assert ParseUtils.parse_float("bad", 1.25) == 1.25
    end

    test "parses strings and passes through numeric values" do
      assert ParseUtils.parse_float("2.5", 0.0) == 2.5
      assert ParseUtils.parse_float(1.5, 0.0) == 1.5
      assert ParseUtils.parse_float(2, 0.0) == 2.0
    end
  end

  describe "parse_bool/2" do
    test "returns default for nil" do
      assert ParseUtils.parse_bool(nil, true)
      refute ParseUtils.parse_bool(nil, false)
    end

    test "accepts known true-like values and rejects others" do
      assert ParseUtils.parse_bool(true, false)
      assert ParseUtils.parse_bool("true", false)
      assert ParseUtils.parse_bool("1", false)
      assert ParseUtils.parse_bool(1, false)

      refute ParseUtils.parse_bool(false, true)
      refute ParseUtils.parse_bool("false", true)
      refute ParseUtils.parse_bool("0", true)
      refute ParseUtils.parse_bool(0, true)
    end
  end
end
