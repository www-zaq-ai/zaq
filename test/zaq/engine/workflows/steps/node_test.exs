defmodule Zaq.Engine.Workflows.Step.NodeTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Engine.Workflows.Step.Node

  property "non-map inline nodes return a validation error for arbitrary terms" do
    check all(attrs <- term() |> filter(&(not is_map(&1)))) do
      assert {:error, "must be a node object"} = Node.validate_node_map(attrs)
    end
  end
end
