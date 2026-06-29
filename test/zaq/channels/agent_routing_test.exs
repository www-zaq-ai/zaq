defmodule RejectingAgent do
  def get_conversation_enabled_agent(_id), do: raise("agent lookup should not be called")
end

defmodule Zaq.Channels.AgentRoutingTest do
  use ExUnit.Case, async: true

  alias Zaq.Channels.AgentRouting

  describe "select_value/1" do
    test "normalizes NONE choices to the persisted NONE sentinel" do
      none = AgentRouting.none_value()

      assert AgentRouting.select_value(none) == none
      assert AgentRouting.select_value("none") == none
      assert AgentRouting.select_value(:none) == none
    end
  end

  describe "validate_choice/2" do
    test "returns :none for persisted, string, and atom NONE values" do
      none = AgentRouting.none_value()

      assert AgentRouting.validate_choice(none, RejectingAgent) == {:ok, :none}
      assert AgentRouting.validate_choice("none", RejectingAgent) == {:ok, :none}
      assert AgentRouting.validate_choice(:none, RejectingAgent) == {:ok, :none}
    end
  end

  describe "resolve_selection/1" do
    test "returns nil for empty candidates using the default agent module" do
      candidates = []

      assert AgentRouting.resolve_selection(candidates) == {:ok, nil}
    end
  end
end
