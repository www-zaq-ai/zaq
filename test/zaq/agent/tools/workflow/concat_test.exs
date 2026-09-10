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

    test "does not return a matrix unless as_matrix is set" do
      assert {:ok, result} = Concat.run(%{parts: ["a"]}, %{})
      refute Map.has_key?(result, :matrix)
    end

    test "wraps the result as a 1x1 matrix when as_matrix is true" do
      assert {:ok, %{result: "3", matrix: [["3"]]}} =
               Concat.run(%{parts: [3], as_matrix: true}, %{})
    end

    test "accepts as_matrix as the string \"true\"" do
      assert {:ok, %{matrix: [["3"]]}} =
               Concat.run(%{"parts" => [3], "as_matrix" => "true"}, %{})
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

  describe "list mode (auto-detected)" do
    test "builds an agent message array from a seeded turn and prior conversation" do
      # Placeholders are resolved by `StepRunner` before `run/2`, so the parts
      # arrive as the literal values below.
      params = %{
        parts: [
          [%{"role" => "assistant", "content" => "You are helpful"}],
          [%{role: "user", content: "hi"}, %{role: "assistant", content: "yo"}]
        ]
      }

      assert {:ok, %{list: list}} = Concat.run(params, %{})

      assert list == [
               %{"role" => "assistant", "content" => "You are helpful"},
               %{role: "user", content: "hi"},
               %{role: "assistant", content: "yo"}
             ]

      refute Map.has_key?(%{list: list}, :result)
    end

    test "concatenates two literal lists in order" do
      assert {:ok, %{list: [1, 2, 3, 4]}} = Concat.run(%{parts: [[1, 2], [3, 4]]}, %{})
    end

    test "wraps a scalar part when another part is a list" do
      assert {:ok, %{list: ["header", %{a: 1}]}} =
               Concat.run(%{parts: ["header", [%{a: 1}]]}, %{})
    end

    test "concatenating empty inner lists yields an empty list" do
      assert {:ok, %{list: []}} = Concat.run(%{parts: [[], []]}, %{})
    end

    test "does not stringify native map elements" do
      assert {:ok, %{list: [%{id: 1}, %{id: 2}]}} =
               Concat.run(%{parts: [[%{id: 1}], [%{id: 2}]]}, %{})
    end
  end
end
