defmodule Zaq.Contracts.Sheets.CoercionTest do
  use ExUnit.Case, async: true

  alias Zaq.Contracts.Sheets.Coercion

  describe "scalar/1" do
    test "guarded pass-through" do
      assert Coercion.scalar("abc") == "abc"
      assert Coercion.scalar(123) == 123
      assert Coercion.scalar(1.5) == 1.5
      assert Coercion.scalar(true) == true
      assert Coercion.scalar(false) == false
      assert Coercion.scalar(nil) == nil
    end

    test "atom coercion" do
      assert Coercion.scalar(:ok) == "ok"
      assert Coercion.scalar(:with_underscore) == "with_underscore"
    end

    test "fallback inspect" do
      assert Coercion.scalar(%{a: 1}) == "%{a: 1}"
      assert Coercion.scalar([1, 2, 3]) == "[1, 2, 3]"
      assert Coercion.scalar({:ok, 1}) == "{:ok, 1}"
    end
  end
end
