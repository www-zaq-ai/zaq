defmodule ZaqWeb.Components.AgentTracePanelTest do
  use ZaqWeb.ConnCase, async: true
  use ExUnitProperties

  import Phoenix.LiveViewTest

  alias ZaqWeb.Components.AgentTracePanel

  describe "agent_trace_panel/1" do
    property "valid hierarchy shape is independent of parent arrival order" do
      check all(
              order <- member_of([[0, 1, 2], [2, 1, 0], [1, 0, 2], [2, 0, 1]]),
              suffix <- string(:alphanumeric, min_length: 1, max_length: 20),
              max_runs: 20
            ) do
        root = "opaque.root.#{suffix}"

        traces = [
          %{"id" => root, "type" => "tool_call"},
          %{
            "id" => "child",
            "origin" => "zaq_action",
            "invocation_path" => [root, "a"],
            "parent_id" => root
          },
          %{
            "id" => "grandchild",
            "origin" => "zaq_action",
            "invocation_path" => [root, "a", "b"],
            "parent_id" => "child"
          }
        ]

        html =
          render_component(&AgentTracePanel.agent_trace_panel/1,
            message_info: %{traces: Enum.map(order, &Enum.at(traces, &1))},
            toggle_event: "toggle"
          )

        assert Regex.scan(~r/data-testid="trace-row-([^"]+)"/, html) |> Enum.map(&List.last/1) ==
                 [root, "child", "grandchild"]

        assert html =~ ~s(data-trace-depth="2")
      end
    end

    test "duplicate tool IDs do not share a DOM expansion key" do
      traces = [
        %{"id" => "duplicate", "type" => "tool_call"},
        %{"id" => "duplicate", "type" => "tool_call"}
      ]

      html =
        render_component(&AgentTracePanel.agent_trace_panel/1,
          message_info: %{traces: traces},
          toggle_event: "toggle"
        )

      keys = Regex.scan(~r/data-testid="trace-row-([^"]+)"/, html) |> Enum.map(&List.last/1)
      assert length(keys) == 2
      assert length(Enum.uniq(keys)) == 2
    end

    test "a caller panel ID is unique rather than repeated on every row button" do
      html =
        render_component(&AgentTracePanel.agent_trace_panel/1,
          message_info: %{traces: [%{"id" => "one"}, %{"id" => "two"}]},
          id: "unique-panel",
          toggle_event: "toggle"
        )

      assert length(Regex.scan(~r/ id="unique-panel"/, html)) == 1
    end

    test "derives a stable three-level hierarchy even when children arrive before their parent" do
      traces = [
        %{
          "id" => "grandchild",
          "type" => "tool_call",
          "origin" => "zaq_action",
          "invocation_path" => ["opaque.root", "a", "b"],
          "parent_id" => "child",
          "name" => "grandchild",
          "outcome" => "failed"
        },
        %{
          "id" => "child",
          "type" => "tool_call",
          "origin" => "zaq_action",
          "invocation_path" => ["opaque.root", "a"],
          "parent_id" => "opaque.root",
          "name" => "child",
          "outcome" => "succeeded"
        },
        %{"id" => "opaque.root", "type" => "tool_call", "name" => "parent"}
      ]

      html =
        render_component(&AgentTracePanel.agent_trace_panel/1,
          message_info: %{traces: traces},
          toggle_event: "toggle_trace_details",
          expanded_ids: MapSet.new(["child"])
        )

      assert Regex.scan(~r/data-testid="trace-row-([^"]+)"/, html) |> Enum.map(&List.last/1) ==
               ["opaque.root", "child", "grandchild"]

      assert html =~ ~s(data-trace-depth="2")
      assert html =~ "trace-details-child"
      assert html =~ "Failed"
    end

    test "malformed parents and duplicate IDs remain visible without recursive cycles" do
      traces =
        for {id, parent, path} <- [{"a", "b", ["missing", "x"]}, {"b", "a", ["missing", "y"]}] do
          %{
            "id" => id,
            "type" => "tool_call",
            "origin" => "zaq_action",
            "parent_id" => parent,
            "invocation_path" => path
          }
        end

      html =
        render_component(&AgentTracePanel.agent_trace_panel/1,
          message_info: %{traces: traces},
          toggle_event: "toggle"
        )

      assert html =~ "trace-row-a"
      assert html =~ "trace-row-b"
      assert html =~ "Unattached"
    end

    test "the workflow card supplies an external root without a duplicate root row" do
      traces = [
        %{
          "id" => "child",
          "type" => "tool_call",
          "origin" => "zaq_action",
          "invocation_path" => ["workflow_step:uuid", "a"],
          "parent_id" => "workflow_step:uuid",
          "outcome" => "unknown"
        }
      ]

      html =
        render_component(&AgentTracePanel.agent_trace_panel/1,
          message_info: %{traces: traces, root_invocation_id: "workflow_step:uuid"},
          toggle_event: "toggle"
        )

      assert html =~ "trace-row-child"
      refute html =~ "trace-row-workflow_step:uuid"
      refute html =~ "Unattached"
      assert html =~ "Unknown"
    end

    test "renders agent, model, measurements, and traces, honoring rest/testid attrs" do
      message_info = %{
        agent: %{"name" => "Bot"},
        model: "gpt-4",
        measurements: %{"latency_ms" => 42},
        traces: [%{"id" => "t1", "type" => "content", "duration_ms" => 5}]
      }

      html =
        render_component(&AgentTracePanel.agent_trace_panel/1,
          message_info: message_info,
          expanded_ids: MapSet.new(),
          toggle_event: "toggle_step_trace_details",
          testid: "agent-trace-panel-step-1",
          "phx-value-step_run_id": "step-1"
        )

      assert html =~ "data-testid=\"agent-trace-panel-step-1\""
      assert html =~ "Bot"
      assert html =~ "gpt-4"
      assert html =~ "latency_ms"
      assert html =~ "Traces (1)"
      assert html =~ "data-testid=\"trace-row-t1\""
      assert html =~ "phx-value-step_run_id=\"step-1\""
      refute html =~ "data-testid=\"trace-details-t1\""
    end

    test "renders defaults with no crash when message_info is empty" do
      html =
        render_component(&AgentTracePanel.agent_trace_panel/1,
          expanded_ids: MapSet.new(),
          toggle_event: "toggle_trace_details"
        )

      assert html =~ "data-testid=\"agent-trace-panel\""
      assert html =~ "No measurements available."
      assert html =~ "Traces (0)"
    end

    test "expands a trace row's JSON detail when its id is in expanded_ids" do
      message_info = %{traces: [%{"id" => "t1", "type" => "content"}]}

      html =
        render_component(&AgentTracePanel.agent_trace_panel/1,
          message_info: message_info,
          expanded_ids: MapSet.new(["t1"]),
          toggle_event: "toggle_trace_details"
        )

      assert html =~ "data-testid=\"trace-details-t1\""
      assert html =~ "Copy trace JSON"
    end

    test "renders authenticated artifact links inside expanded trace details" do
      message_info = %{
        traces: [
          %{
            "id" => "tool-media",
            "type" => "tool_call",
            "artifacts" => [
              %{
                "id" => "b3496060-57a3-44a5-9255-a73d2eef62e1",
                "name" => "diagram.png",
                "mime_type" => "image/png",
                "size" => 4
              }
            ]
          }
        ]
      }

      html =
        render_component(&AgentTracePanel.agent_trace_panel/1,
          message_info: message_info,
          expanded_ids: MapSet.new(["tool-media"]),
          toggle_event: "toggle_trace_details"
        )

      assert html =~ "diagram.png"
      assert html =~ ~s(href="/bo/trace-artifacts/b3496060-57a3-44a5-9255-a73d2eef62e1")
      assert html =~ ~s(data-testid="trace-artifact-link")
    end

    test "reasoning and content traces persisted with the same id toggle independently" do
      # Old persisted traces gave both segments of one LLM call the bare call
      # id; the panel must disambiguate them or one row toggles the other.
      message_info = %{
        traces: [
          %{"id" => "llm-1", "type" => "reasoning", "started_at_ms" => 10},
          %{"id" => "llm-1", "type" => "content", "started_at_ms" => 20}
        ]
      }

      html =
        render_component(&AgentTracePanel.agent_trace_panel/1,
          message_info: message_info,
          expanded_ids: MapSet.new(["llm-1:reasoning"]),
          toggle_event: "toggle_trace_details"
        )

      assert html =~ "data-testid=\"trace-row-llm-1:reasoning\""
      assert html =~ "data-testid=\"trace-row-llm-1:content\""
      assert html =~ "data-testid=\"trace-details-llm-1:reasoning\""
      refute html =~ "data-testid=\"trace-details-llm-1:content\""
    end

    test "renders fallback values for non-map message_info" do
      html =
        render_component(&AgentTracePanel.agent_trace_panel/1,
          message_info: "not telemetry",
          toggle_event: "toggle_trace_details"
        )

      assert html =~ "n/a"
      assert html =~ "No measurements available."
      assert html =~ "Traces (0)"
    end

    test "formats legacy tool traces, float durations, blank measurements, and fallback JSON" do
      message_info = %{
        "agent" => "",
        "model" => "",
        "measurements" => %{"blank" => "", "none" => nil, "ok" => "ready"},
        "traces" => [
          %{
            "tool_name" => "lookup.user",
            "tool_call_id" => "call-1",
            "duration_ms" => 12.345,
            "started_at_ms" => 10.5,
            "bad" => self()
          },
          %{
            "id" => 123,
            "type" => nil,
            "duration_ms" => nil,
            "started_at" => "2026-07-03T10:00:00Z"
          },
          %{}
        ]
      }

      html =
        render_component(&AgentTracePanel.agent_trace_panel/1,
          message_info: message_info,
          expanded_ids: MapSet.new(["call-1"]),
          toggle_event: "toggle_trace_details"
        )

      assert html =~ "Tool Call · Lookup User"
      assert html =~ "12.35 ms"
      assert html =~ "Trace"
      assert html =~ "data-testid=\"trace-row-123\""
      assert html =~ "data-testid=\"trace-details-call-1\""
      assert html =~ "blank"
      assert html =~ "ready"
      assert html =~ "n/a"
      assert html =~ "#PID"
    end
  end
end
