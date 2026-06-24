defmodule Zaq.Agent.Tools.Workflow.IncrementTest do
  use ExUnit.Case, async: true

  alias Zaq.Agent.Tools.Workflow.Increment

  describe "run/2" do
    test "increments an integer value by 1" do
      assert {:ok, %{value: 3}} = Increment.run(%{value: 2}, %{})
    end

    test "coerces a string value (as returned by a sheet cell) before incrementing" do
      assert {:ok, %{value: 3}} = Increment.run(%{value: "2"}, %{})
    end

    test "coerces a string value with surrounding whitespace" do
      assert {:ok, %{value: 6}} = Increment.run(%{value: " 5 "}, %{})
    end

    test "reads the value from a string key when no atom key is present" do
      assert {:ok, %{value: 8}} = Increment.run(%{"value" => "7"}, %{})
    end

    test "preserves other params that pass through the node" do
      assert {:ok, %{value: 4, row: 9}} = Increment.run(%{value: 3, row: 9}, %{})
    end

    test "returns an error for a non-numeric string instead of raising" do
      assert {:error, message} = Increment.run(%{value: "abc"}, %{})
      assert message =~ "requires an integer value"
    end

    test "returns an error when the value is missing" do
      assert {:error, message} = Increment.run(%{}, %{})
      assert message =~ "requires an integer value"
    end

    test "returns an error when the value is nil" do
      assert {:error, _message} = Increment.run(%{value: nil}, %{})
    end
  end
end
