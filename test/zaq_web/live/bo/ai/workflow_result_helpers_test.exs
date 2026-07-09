defmodule ZaqWeb.Live.BO.AI.WorkflowResultHelpersTest do
  use ExUnit.Case, async: true

  alias ZaqWeb.Live.BO.AI.WorkflowResultHelpers, as: Helpers

  describe "clean_results/1" do
    test "returns an empty map for nil" do
      assert Helpers.clean_results(nil) == %{}
    end

    test "strips __cascade__ (both key forms) and nested __cascade__ entries" do
      results = %{
        "output" => "hi",
        "__cascade__" => %{step: %{}},
        :__cascade__ => %{step: %{}},
        "nested" => %{"__cascade__" => true}
      }

      assert Helpers.clean_results(results) == %{"output" => "hi"}
    end

    test "strips trace/agent/model/measurements (both key forms) so they don't render twice" do
      results = %{
        "output" => "hi",
        "trace" => [%{"id" => "1"}],
        :agent => %{"name" => "Bot"},
        "model" => "gpt-4",
        :measurements => %{"latency_ms" => 5}
      }

      assert Helpers.clean_results(results) == %{"output" => "hi"}
    end

    test "leaves an unrelated map untouched" do
      results = %{"output" => "hi", "count" => 3}
      assert Helpers.clean_results(results) == results
    end
  end

  describe "agent_trace_info/1" do
    test "extracts agent/model/measurements/traces from a string-keyed results map" do
      results = %{
        "output" => "hi",
        "trace" => [%{"id" => "1"}],
        "agent" => %{"name" => "Bot"},
        "model" => "gpt-4",
        "measurements" => %{"latency_ms" => 5}
      }

      assert Helpers.agent_trace_info(results) == %{
               agent: %{"name" => "Bot"},
               model: "gpt-4",
               measurements: %{"latency_ms" => 5},
               traces: [%{"id" => "1"}]
             }
    end

    test "extracts from an atom-keyed results map too" do
      results = %{trace: [%{"id" => "1"}], agent: %{"name" => "Bot"}, model: "gpt-4"}

      assert Helpers.agent_trace_info(results) == %{
               agent: %{"name" => "Bot"},
               model: "gpt-4",
               measurements: %{},
               traces: [%{"id" => "1"}]
             }
    end

    test "returns safe defaults for a results map with none of the keys" do
      assert Helpers.agent_trace_info(%{"output" => "done"}) == %{
               agent: nil,
               model: nil,
               measurements: %{},
               traces: []
             }
    end

    test "returns safe defaults for non-map input" do
      assert Helpers.agent_trace_info(nil) == %{
               agent: nil,
               model: nil,
               measurements: %{},
               traces: []
             }
    end
  end

  describe "agent_trace_available?/1" do
    test "false when results has none of the four signal fields" do
      refute Helpers.agent_trace_available?(%{"output" => "done"})
    end

    test "false for nil" do
      refute Helpers.agent_trace_available?(nil)
    end

    test "true when only agent is present" do
      assert Helpers.agent_trace_available?(%{"agent" => %{"name" => "Bot"}})
    end

    test "true when only model is present" do
      assert Helpers.agent_trace_available?(%{"model" => "gpt-4"})
    end

    test "true when only traces is non-empty" do
      assert Helpers.agent_trace_available?(%{"trace" => [%{"id" => "1"}]})
    end

    test "true when only measurements is non-empty" do
      assert Helpers.agent_trace_available?(%{"measurements" => %{"latency_ms" => 1}})
    end

    test "false when traces is an empty list and measurements is an empty map" do
      refute Helpers.agent_trace_available?(%{"trace" => [], "measurements" => %{}})
    end
  end
end
