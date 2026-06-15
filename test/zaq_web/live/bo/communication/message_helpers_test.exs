defmodule ZaqWeb.Live.BO.Communication.MessageHelpersTest do
  use ExUnit.Case, async: true

  alias ZaqWeb.Live.BO.Communication.MessageHelpers

  describe "positive_rater_attrs/1" do
    test "returns anonymous attrs when current user is nil" do
      assert MessageHelpers.positive_rater_attrs(nil) == %{
               channel_user_id: "bo_anonymous",
               rating: 5
             }
    end
  end

  describe "negative_rater_attrs/3" do
    test "returns anonymous attrs and joined feedback fields when current user is nil" do
      attrs = MessageHelpers.negative_rater_attrs(nil, ["Not accurate"], "Missing context")

      assert attrs == %{
               channel_user_id: "bo_anonymous",
               rating: 1,
               comment: "Not accurate\nMissing context",
               feedback_reasons: ["Not accurate"]
             }
    end
  end

  describe "normalize_tool_calls/1" do
    test "returns empty list for non-list input" do
      assert MessageHelpers.normalize_tool_calls(nil) == []
      assert MessageHelpers.normalize_tool_calls(%{}) == []
    end

    test "normalizes key fields without applying ordering" do
      tool_calls = [
        %{"tool_call_id" => "bad", "response_time_ms" => "n/a"},
        %{"tool_call_id" => "float", "response_time_ms" => 12.5}
      ]

      [first, second] = MessageHelpers.normalize_tool_calls(tool_calls)
      assert first.tool_call_id == "bad"
      assert second.tool_call_id == "float"
      assert first.response_time_ms == "n/a"
      assert second.response_time_ms == 12.5
    end
  end

  describe "toggle_tool_call_details/2" do
    test "removes existing tool id from expanded set" do
      expanded = MapSet.new(["tool-1"])
      assert MessageHelpers.toggle_tool_call_details(expanded, "tool-1") == MapSet.new()
    end

    test "adds missing tool id to expanded set" do
      expanded = MapSet.new()

      assert MessageHelpers.toggle_tool_call_details(expanded, "tool-2") ==
               MapSet.new(["tool-2"])
    end
  end

  describe "message_info_from_runtime/1" do
    test "returns empty info for non-map runtime metadata" do
      assert MessageHelpers.message_info_from_runtime(nil) == %{
               agent: nil,
               model: nil,
               measurements: %{},
               traces: []
             }
    end

    test "uses configured agent name when runtime metadata has no agent" do
      info = MessageHelpers.message_info_from_runtime(%{configured_agent_name: "Support Agent"})

      assert info.agent == %{"name" => "Support Agent"}
      assert info.model == nil

      assert info.measurements == %{
               "prompt_tokens" => "not provided",
               "completion_tokens" => "not provided",
               "total_tokens" => "not provided"
             }

      assert info.traces == []
    end

    test "uses canonical measurement construction for runtime metadata" do
      info =
        MessageHelpers.message_info_from_runtime(%{
          measurements: %{
            "latency_ms" => 12,
            "input_tokens" => 999,
            "output_tokens" => 999,
            "total_tokens" => 999
          },
          prompt_tokens: 3,
          completion_tokens: 4,
          total_tokens: 7
        })

      assert info.measurements == %{
               "latency_ms" => 12,
               "prompt_tokens" => 3,
               "completion_tokens" => 4,
               "total_tokens" => 7
             }
    end

    test "ignores invalid trace and legacy tool calls" do
      info =
        MessageHelpers.message_info_from_runtime(%{
          trace: :not_a_trace,
          tool_calls: :not_tool_calls
        })

      assert info.traces == []
    end
  end

  describe "message_info_from_message/1" do
    test "returns empty info for nil message" do
      assert MessageHelpers.message_info_from_message(nil) == MessageHelpers.empty_message_info()
    end

    test "uses trace when present and ignores legacy tool calls" do
      info =
        MessageHelpers.message_info_from_message(%{
          model: "gpt-4o",
          prompt_tokens: 3,
          completion_tokens: 4,
          total_tokens: 7,
          trace: [%{"id" => "trace-1", "type" => "content"}],
          metadata: %{
            "tool_calls" => [%{"tool_call_id" => "legacy"}],
            "measurements" => %{"latency_ms" => 12},
            "agent" => %{"name" => "Agent"}
          }
        })

      assert info.model == "gpt-4o"
      assert info.agent == %{"name" => "Agent"}

      assert info.measurements == %{
               "latency_ms" => 12,
               "prompt_tokens" => 3,
               "completion_tokens" => 4,
               "total_tokens" => 7
             }

      assert info.traces == [%{"id" => "trace-1", "type" => "content"}]
    end

    test "uses message token columns instead of duplicated metadata token measurements" do
      info =
        MessageHelpers.message_info_from_message(%{
          prompt_tokens: 10,
          completion_tokens: 5,
          total_tokens: 15,
          metadata: %{
            "measurements" => %{
              "latency_ms" => 42,
              "input_tokens" => 999,
              "output_tokens" => 999,
              "total_tokens" => 999
            }
          }
        })

      assert info.measurements == %{
               "latency_ms" => 42,
               "prompt_tokens" => 10,
               "completion_tokens" => 5,
               "total_tokens" => 15
             }
    end

    test "shows not provided token measurements when token columns are empty" do
      info =
        MessageHelpers.message_info_from_message(%{
          role: "assistant",
          metadata: %{}
        })

      assert info.measurements == %{
               "prompt_tokens" => "not provided",
               "completion_tokens" => "not provided",
               "total_tokens" => "not provided"
             }

      assert MessageHelpers.message_info_available?(info)
    end

    test "falls back to legacy metadata tool calls when trace is empty" do
      legacy = %{"tool_call_id" => "legacy", "tool_name" => "lookup"}

      info =
        MessageHelpers.message_info_from_message(%{
          trace: [],
          metadata: %{"tool_calls" => [legacy]}
        })

      assert info.traces == [legacy]
      assert MessageHelpers.message_info_available?(info)
    end

    test "empty persisted message info is available through not provided token rows" do
      info = MessageHelpers.message_info_from_message(%{})

      assert info.measurements == %{
               "prompt_tokens" => "not provided",
               "completion_tokens" => "not provided",
               "total_tokens" => "not provided"
             }

      assert MessageHelpers.message_info_available?(info)
    end

    test "filters non-map trace entries" do
      info =
        MessageHelpers.message_info_from_message(%{
          trace: [%{"id" => "trace-1"}, "bad", nil],
          metadata: %{}
        })

      assert info.traces == [%{"id" => "trace-1"}]
    end
  end

  describe "message_info_available?/1" do
    test "returns true when string-key measurements are present" do
      assert MessageHelpers.message_info_available?(%{"measurements" => %{"latency_ms" => 42}})
    end

    test "ignores non-map measurements" do
      refute MessageHelpers.message_info_available?(%{measurements: "not-a-map"})
    end

    test "ignores non-list traces" do
      refute MessageHelpers.message_info_available?(%{traces: "not-a-list"})
    end

    test "returns false for non-map input" do
      refute MessageHelpers.message_info_available?(nil)
    end
  end

  describe "toggle_trace_details/2" do
    test "removes existing trace id from expanded set" do
      expanded = MapSet.new(["trace-1"])
      assert MessageHelpers.toggle_trace_details(expanded, "trace-1") == MapSet.new()
    end
  end
end
