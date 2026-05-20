defmodule Zaq.Engine.Workflows.Steps.EdgeStepTest do
  use ExUnit.Case, async: true

  alias Zaq.Engine.Workflows.Conditions.ConditionNotMet
  alias Zaq.Engine.Workflows.Steps.EdgeStep

  # Helper to call EdgeStep.run directly.
  defp run(params), do: EdgeStep.run(params, %{})

  describe "no condition, no mapping (identity)" do
    test "passes fact through unchanged" do
      fact = %{name: "Sam", age: 30}

      params =
        Map.merge(%{__edge_condition__: nil, __edge_mapping__: %{}, __edge_name__: "e"}, fact)

      assert {:ok, ^fact} = run(params)
    end
  end

  describe "condition — passes" do
    test "returns fact when condition is true" do
      fact = %{gender: "male"}

      params =
        Map.merge(
          %{
            __edge_condition__: %{"field" => "gender", "op" => "eq", "value" => "male"},
            __edge_mapping__: %{},
            __edge_name__: "e"
          },
          fact
        )

      assert {:ok, ^fact} = run(params)
    end
  end

  describe "condition — fails" do
    test "raises ConditionNotMet when condition is false" do
      fact = %{gender: "female"}

      params =
        Map.merge(
          %{
            __edge_condition__: %{"field" => "gender", "op" => "eq", "value" => "male"},
            __edge_mapping__: %{},
            __edge_name__: "b_to_c"
          },
          fact
        )

      assert_raise ConditionNotMet, fn -> run(params) end
    end

    test "ConditionNotMet carries correct metadata" do
      fact = %{score: 3}

      params =
        Map.merge(
          %{
            __edge_condition__: %{"field" => "score", "op" => "gt", "value" => 5},
            __edge_mapping__: %{},
            __edge_name__: "test_edge"
          },
          fact
        )

      assert_raise ConditionNotMet, fn -> run(params) end

      try do
        run(params)
      rescue
        e in ConditionNotMet ->
          assert e.field == "score"
          assert e.op == :gt
          assert e.actual == 3
          assert e.expected == 5
          assert e.condition_name == "test_edge"
      end
    end
  end

  describe "mapping — key rename" do
    test "renames source key to target key" do
      fact = %{name: "Sam", age: 30, gender: "male"}

      params =
        Map.merge(
          %{
            __edge_condition__: nil,
            __edge_mapping__: %{"person_name" => "name"},
            __edge_name__: "e"
          },
          fact
        )

      {:ok, result} = run(params)
      assert result[:person_name] == "Sam"
      # Source key consumed — not passed through.
      refute Map.has_key?(result, :name)
      # Unmapped keys passed through.
      assert result[:age] == 30
      assert result[:gender] == "male"
    end

    test "multiple mappings rename all specified keys" do
      fact = %{a: 1, b: 2, c: 3}

      params =
        Map.merge(
          %{
            __edge_condition__: nil,
            __edge_mapping__: %{"x" => "a", "y" => "b"},
            __edge_name__: "e"
          },
          fact
        )

      {:ok, result} = run(params)
      assert result[:x] == 1
      assert result[:y] == 2
      refute Map.has_key?(result, :a)
      refute Map.has_key?(result, :b)
      assert result[:c] == 3
    end

    test "missing source key maps to nil" do
      fact = %{age: 30}

      params =
        Map.merge(
          %{
            __edge_condition__: nil,
            __edge_mapping__: %{"person_name" => "name"},
            __edge_name__: "e"
          },
          fact
        )

      {:ok, result} = run(params)
      assert result[:person_name] == nil
      assert result[:age] == 30
    end
  end

  describe "condition + mapping combined" do
    test "applies mapping when condition passes" do
      fact = %{gender: "male", name: "Sam"}

      params =
        Map.merge(
          %{
            __edge_condition__: %{"field" => "gender", "op" => "eq", "value" => "male"},
            __edge_mapping__: %{"person_name" => "name"},
            __edge_name__: "e"
          },
          fact
        )

      {:ok, result} = run(params)
      assert result[:person_name] == "Sam"
      refute Map.has_key?(result, :name)
    end

    test "raises ConditionNotMet before mapping when condition fails" do
      fact = %{gender: "female", name: "Sam"}

      params =
        Map.merge(
          %{
            __edge_condition__: %{"field" => "gender", "op" => "eq", "value" => "male"},
            __edge_mapping__: %{"person_name" => "name"},
            __edge_name__: "e"
          },
          fact
        )

      assert_raise ConditionNotMet, fn -> run(params) end
    end
  end

  describe "mapping — atom-keyed mapping (lookup/to_key atom fallbacks)" do
    test "atom source and target keys in mapping are handled correctly" do
      fact = %{name: "Sam", age: 30}

      params =
        Map.merge(
          %{
            __edge_condition__: nil,
            __edge_mapping__: %{person_name: :name},
            __edge_name__: "e"
          },
          fact
        )

      {:ok, result} = run(params)
      assert result[:person_name] == "Sam"
      refute Map.has_key?(result, :name)
      assert result[:age] == 30
    end
  end

  describe "absent edge metadata keys" do
    test "works with no edge keys in params at all (identity)" do
      # EdgeStep strips known keys; if they are absent from params it still works.
      fact = %{foo: "bar"}
      assert {:ok, ^fact} = run(fact)
    end
  end
end
