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
  end
end
