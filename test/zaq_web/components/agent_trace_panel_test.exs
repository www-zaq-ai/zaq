defmodule ZaqWeb.Components.AgentTracePanelTest do
  use ZaqWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ZaqWeb.Components.AgentTracePanel

  describe "agent_trace_panel/1" do
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
  end
end
