defmodule Zaq.Agent.Tools.Workflow.ConcatTest do
  use ExUnit.Case, async: true

  alias Zaq.Agent.Tools.Workflow.Concat

  describe "run/2" do
    test "joins parts with no separator by default" do
      assert {:ok, %{result: "abc"}} = Concat.run(%{parts: ["a", "b", "c"]}, %{})
    end

    test "joins parts with a custom separator" do
      assert {:ok, %{result: "x-y-z"}} =
               Concat.run(%{parts: ["x", "y", "z"], separator: "-"}, %{})
    end

    test "coerces non-string parts to strings" do
      assert {:ok, %{result: "row5"}} = Concat.run(%{parts: ["row", 5]}, %{})
    end

    test "substitutes {{key}} placeholders from atom-keyed params" do
      assert {:ok, %{result: "J5"}} =
               Concat.run(%{parts: ["{{column}}{{row}}"], column: "J", row: 5}, %{})
    end

    test "substitutes {{key}} placeholders from string-keyed params" do
      assert {:ok, %{result: "Sheet1!J5"}} =
               Concat.run(
                 %{"parts" => ["Sheet1!{{column}}{{row}}"], "column" => "J", "row" => 5},
                 %{}
               )
    end

    test "tolerates surrounding whitespace inside placeholders" do
      assert {:ok, %{result: "J5"}} =
               Concat.run(%{parts: ["{{ column }}{{ row }}"], column: "J", row: 5}, %{})
    end

    test "renders a missing placeholder as an empty string" do
      assert {:ok, %{result: "J"}} = Concat.run(%{parts: ["{{column}}{{row}}"], column: "J"}, %{})
    end

    test "does not return a matrix unless as_matrix is set" do
      assert {:ok, result} = Concat.run(%{parts: ["a"]}, %{})
      refute Map.has_key?(result, :matrix)
    end

    test "wraps the result as a 1x1 matrix when as_matrix is true" do
      assert {:ok, %{result: "3", matrix: [["3"]]}} =
               Concat.run(%{parts: ["{{value}}"], value: 3, as_matrix: true}, %{})
    end

    test "accepts as_matrix as the string \"true\"" do
      assert {:ok, %{matrix: [["3"]]}} =
               Concat.run(%{"parts" => ["{{value}}"], "value" => 3, "as_matrix" => "true"}, %{})
    end

    test "reserved keys are excluded from placeholder substitution" do
      assert {:ok, %{result: ""}} =
               Concat.run(%{parts: ["{{separator}}{{parts}}{{as_matrix}}"], separator: "-"}, %{})
    end

    test "returns an error when parts is not a list" do
      assert {:error, message} = Concat.run(%{parts: "nope"}, %{})
      assert message =~ "requires a list of parts"
    end

    test "returns an error when parts is missing" do
      assert {:error, message} = Concat.run(%{}, %{})
      assert message =~ "requires a list of parts"
    end
  end
end
