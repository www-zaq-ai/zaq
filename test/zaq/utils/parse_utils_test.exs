defmodule Zaq.Utils.ParseUtilsTest do
  use ExUnit.Case, async: true

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
end
