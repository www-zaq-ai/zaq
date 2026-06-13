defmodule Zaq.HelpersTest do
  use ExUnit.Case, async: true

  doctest Zaq.Helpers

  alias Zaq.Helpers

  describe "blank?/1" do
    test "nil is blank" do
      assert Helpers.blank?(nil)
    end

    test "empty and whitespace-only strings are blank" do
      assert Helpers.blank?("")
      assert Helpers.blank?(" ")
      assert Helpers.blank?("   ")
      assert Helpers.blank?("\t\n ")
    end

    test "non-empty strings are not blank" do
      refute Helpers.blank?("x")
      refute Helpers.blank?("  x  ")
    end

    test "non-nil, non-binary values are not blank" do
      refute Helpers.blank?(0)
      refute Helpers.blank?(false)
      refute Helpers.blank?(:atom)
      refute Helpers.blank?(%{})
      refute Helpers.blank?([])
    end
  end
end
