defmodule Zaq.Agent.Tools.Workflow.IncrementTest do
  use ExUnit.Case, async: true

  alias Zaq.Agent.Tools.Workflow.Increment

  describe "run/2" do
    test "increments an integer value by 1" do
      assert {:ok, %{value: 3}} = Increment.run(%{value: 2}, %{})
    end

    test "preserves other params that pass through the node" do
      assert {:ok, %{value: 4, row: 9}} = Increment.run(%{value: 3, row: 9}, %{})
    end
  end
end
