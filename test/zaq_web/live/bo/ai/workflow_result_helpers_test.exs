defmodule ZaqWeb.Live.BO.AI.WorkflowResultHelpersTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ZaqWeb.Live.BO.AI.WorkflowResultHelpers, as: Helpers

  property "replayed starts and completions cannot downgrade an explicit outcome" do
    check all(
            outcome <- member_of(~w(succeeded failed unknown)),
            repetitions <- integer(1..5),
            max_runs: 20
          ) do
      data = %{
        "origin" => "zaq_action",
        "invocation_path" => ["workflow_step:step", "a"],
        "parent_id" => "workflow_step:step"
      }

      started = %{
        "id" => "start",
        "kind" => "tool_started",
        "tool_call_id" => "child",
        "data" => data
      }

      done = %{
        started
        | "id" => "done",
          "kind" => "tool_completed",
          "data" => Map.put(data, "outcome", outcome)
      }

      events = [done] ++ List.duplicate(started, repetitions) ++ List.duplicate(done, repetitions)
      info = Helpers.step_trace_info(%{id: "step", status: "failed", trace_events: events})
      assert [%{"outcome" => ^outcome, "sequence" => 1}] = info.traces
    end
  end

  test "step events project completion-only, late starts, explicit outcomes and interrupted children" do
    hierarchy = %{
      "origin" => "zaq_action",
      "invocation_path" => ["workflow_step:step", "a"],
      "parent_id" => "workflow_step:step"
    }

    done = %{
      "id" => "done",
      "kind" => "tool_completed",
      "tool_call_id" => "child",
      "tool_name" => "lookup",
      "data" =>
        Map.merge(hierarchy, %{
          "outcome" => "succeeded",
          "result" => ["ok", %{"error" => "incidental payload"}, []],
          "duration_ms" => 2
        })
    }

    start = %{
      "id" => "start",
      "kind" => "tool_started",
      "tool_call_id" => "child",
      "tool_name" => "lookup",
      "data" => Map.put(hierarchy, "arguments", %{"query" => "example"})
    }

    pending = %{start | "id" => "pending", "tool_call_id" => "unfinished"}
    step = %{id: "step", status: "failed", trace_events: [done, start, done, pending]}

    assert %{root_invocation_id: "workflow_step:step", traces: [child, unfinished]} =
             Helpers.step_trace_info(step)

    assert child["outcome"] == "succeeded"
    assert child["arguments"] == %{"query" => "example"}
    assert child["sequence"] == 1
    assert unfinished["outcome"] == "unknown"

    assert Helpers.step_trace_info(%{step | status: "running"}).traces
           |> List.last()
           |> Map.fetch!("outcome") == "running"

    assert Helpers.step_trace_info(%{step | status: "running"}, "cancelled").traces
           |> List.last()
           |> Map.fetch!("outcome") == "unknown"
  end

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
