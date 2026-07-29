defmodule Zaq.Agent.Tools.Messages.UpsertIncomingRoutingRulesTest do
  use Zaq.DataCase, async: false

  alias Zaq.Agent.Tools.Messages.UpsertIncomingRoutingRules

  defmodule FakeNodeRouter do
    def dispatch(event) do
      send(Process.get(:routing_tool_test_pid), {:dispatched, event})
      %{event | response: {:ok, %{count: 1, results: [%{status: "upserted", rule: nil}]}}}
    end
  end

  describe "run/2" do
    setup do
      Process.put(:routing_tool_test_pid, self())
      :ok
    end

    test "dispatches rules to the Engine node" do
      rules = [%{channel_config_id: 12, topic_id: "INBOX", routing_mode: "none"}]

      assert {:ok, %{count: 1, results: [%{status: "upserted", rule: rule}]}} =
               UpsertIncomingRoutingRules.run(%{rules: rules}, %{node_router: FakeNodeRouter})

      assert is_nil(rule)
      assert_receive {:dispatched, event}
      assert event.next_hop.destination == :engine
      assert event.opts[:action] == :upsert_incoming_message_routing_rules
      assert event.request == %{rules: rules}
    end

    test "requires rules to be a list" do
      assert {:error, "rules must be a list"} = UpsertIncomingRoutingRules.run(%{}, %{})
      assert {:error, "rules must be a list"} = UpsertIncomingRoutingRules.run(%{rules: %{}}, %{})
    end
  end
end
