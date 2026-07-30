defmodule Zaq.Agent.Tools.Messages.UpsertIncomingRoutingRulesTest do
  use Zaq.DataCase, async: false

  alias Jido.Action.Tool
  alias Zaq.Agent.Tools.Messages.UpsertIncomingRoutingRules

  defmodule FakeNodeRouter do
    def dispatch(event) do
      send(Process.whereis(__MODULE__), {:dispatched, event})
      %{event | response: {:ok, %{count: 1, results: [%{status: "upserted", rule: nil}]}}}
    end
  end

  describe "run/2" do
    setup do
      if Process.whereis(FakeNodeRouter), do: Process.unregister(FakeNodeRouter)
      Process.register(self(), FakeNodeRouter)

      on_exit(fn ->
        if Process.whereis(FakeNodeRouter), do: Process.unregister(FakeNodeRouter)
      end)

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

    test "is callable through Jido Exec with string-keyed JSON rule params" do
      params = %{
        "rules" => [
          %{
            "person_id" => 1,
            "channel_config_id" => 3,
            "routing_mode" => "agent",
            "configured_agent_id" => 1
          }
        ]
      }

      assert {:ok, %{count: 1, results: [%{status: "upserted"}]}} =
               Jido.Exec.run(UpsertIncomingRoutingRules, params, %{node_router: FakeNodeRouter})

      assert_receive {:dispatched, event}

      assert event.request == %{
               rules: [
                 %{
                   person_id: 1,
                   channel_config_id: 3,
                   routing_mode: "agent",
                   configured_agent_id: 1
                 }
               ]
             }
    end

    test "exposes rules as object array in generated tool parameters" do
      schema = Tool.build_parameters_schema(UpsertIncomingRoutingRules.schema())
      rules = schema[:properties][:rules]

      assert rules[:type] == :array
      assert rules[:items][:type] == :object
      assert Map.has_key?(rules[:items][:properties], :channel_config_id)
      assert Map.has_key?(rules[:items][:properties], :routing_mode)
      assert rules[:items][:properties][:routing_mode][:enum] == ["agent", "none", "clear"]
    end

    test "validates agent routing requires configured_agent_id before dispatch" do
      params = %{"rules" => [%{"channel_config_id" => 3, "routing_mode" => "agent"}]}

      assert {:error, error} =
               Jido.Exec.run(UpsertIncomingRoutingRules, params, %{node_router: FakeNodeRouter})

      assert Exception.message(error) =~ "configured_agent_id is required"
      refute_receive {:dispatched, _event}
    end

    test "validates scoped topic and retrieval rules before dispatch" do
      bad_topic = %{"rules" => [%{"topic_id" => "INBOX", "routing_mode" => "none"}]}

      assert {:error, topic_error} =
               Jido.Exec.run(UpsertIncomingRoutingRules, bad_topic, %{node_router: FakeNodeRouter})

      assert Exception.message(topic_error) =~
               "channel_config_id is required when topic_id is set"

      bad_scope = %{
        "rules" => [
          %{
            "channel_config_id" => 3,
            "retrieval_channel_id" => 4,
            "topic_id" => "INBOX",
            "routing_mode" => "none"
          }
        ]
      }

      assert {:error, scope_error} =
               Jido.Exec.run(UpsertIncomingRoutingRules, bad_scope, %{node_router: FakeNodeRouter})

      assert Exception.message(scope_error) =~
               "retrieval_channel_id and topic_id cannot both be set"

      refute_receive {:dispatched, _event}
    end

    test "requires rules to be a list" do
      assert {:error, "rules must be a list"} = UpsertIncomingRoutingRules.run(%{}, %{})
      assert {:error, "rules must be a list"} = UpsertIncomingRoutingRules.run(%{rules: %{}}, %{})
    end

    test "requires params to be a map" do
      assert {:error, "params must be a map"} =
               UpsertIncomingRoutingRules.run(nil, %{node_router: FakeNodeRouter})

      refute_receive {:dispatched, _event}
    end

    test "on_before_validate_params leaves non-map params unchanged" do
      assert {:ok, [:not, :a, :map]} =
               UpsertIncomingRoutingRules.on_before_validate_params([:not, :a, :map])
    end

    test "validate_rule/1 accepts valid rules" do
      assert :ok =
               UpsertIncomingRoutingRules.validate_rule(%{
                 channel_config_id: 3,
                 routing_mode: "none"
               })
    end

    test "validate_rule/1 rejects non-object rules" do
      assert {:error, "rule must be an object"} =
               UpsertIncomingRoutingRules.validate_rule("not a rule")
    end

    test "validate_rule/1 rejects explicit nil configured_agent_id for agent routing" do
      assert {:error, "configured_agent_id is required when routing_mode is agent"} =
               UpsertIncomingRoutingRules.validate_rule(%{
                 routing_mode: "agent",
                 configured_agent_id: nil
               })
    end

    test "validate_rule/1 rejects retrieval scope with explicit nil channel_config_id" do
      assert {:error, "channel_config_id is required when retrieval_channel_id is set"} =
               UpsertIncomingRoutingRules.validate_rule(%{
                 routing_mode: "none",
                 retrieval_channel_id: 4,
                 channel_config_id: nil
               })
    end

    test "validate_rule/1 rejects topic scope with explicit nil channel_config_id" do
      assert {:error, "channel_config_id is required when topic_id is set"} =
               UpsertIncomingRoutingRules.validate_rule(%{
                 routing_mode: "none",
                 topic_id: "INBOX",
                 channel_config_id: nil
               })
    end
  end
end
