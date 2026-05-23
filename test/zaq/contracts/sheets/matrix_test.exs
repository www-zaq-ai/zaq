defmodule Zaq.Contracts.Sheets.MatrixTest do
  use ExUnit.Case, async: true

  alias Zaq.Contracts.Sheets.Matrix

  describe "normalize/1" do
    test "normalizes nested list rows cell-by-cell" do
      values = [["a", 1, true, nil], [:ok, %{k: 1}, [1, 2]]]

      assert Matrix.normalize(values) == [
               ["a", 1, true, nil],
               ["ok", "%{k: 1}", "[1, 2]"]
             ]
    end

    test "wraps non-list top-level elements into single-cell rows" do
      values = [:ok, 7, %{x: 1}, nil, false]

      assert Matrix.normalize(values) == [
               ["ok"],
               [7],
               ["%{x: 1}"],
               [nil],
               [false]
             ]
    end

    test "returns empty list for non-list input" do
      for value <- ["raw string", 123, %{a: 1}, :atom, true, nil] do
        assert Matrix.normalize(value) == []
      end
    end
  end

  describe "append_rows/2" do
    test "concatenates normalized left and right matrices" do
      values = [[:left_atom], "left_scalar"]
      rows = [["r1", :r2], %{r: 3}]

      assert Matrix.append_rows(values, rows) == [
               ["left_atom"],
               ["left_scalar"],
               ["r1", "r2"],
               ["%{r: 3}"]
             ]
    end
  end
end
