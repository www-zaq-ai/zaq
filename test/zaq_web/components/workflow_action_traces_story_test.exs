defmodule ZaqWeb.Components.WorkflowActionTracesStoryTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Storybook.Workflows.ActionTraces
  alias ZaqWeb.Live.BO.AI.WorkflowResultHelpers

  test "workflow story is separate from Chat and renders a labeled step with nested calls" do
    refute File.exists?(
             Path.expand("../../../storybook/chat/workflow_action_traces.story.exs", __DIR__)
           )

    for variation <- ActionTraces.variations() do
      html = render_component(ActionTraces.function(), variation.attributes)

      rows =
        Regex.scan(
          ~r/<li[^>]*data-trace-depth="(\d+)"[^>]*>\s*<button[^>]*data-testid="trace-row-([^"]+)"/s,
          html
        )

      assert Enum.map(rows, fn [_, depth, id] -> {depth, id} end) ==
               [{"0", "search"}, {"1", "lookup"}, {"0", "download"}]

      assert html =~ ~s(id="preview-step-review-step")
      assert html =~ "Review documents"
      assert html =~ "Selected workflow step"
      assert html =~ "Action invocations"
      assert html =~ "Input"
    end
  end

  test "fixtures retain successful child evidence while the sibling runs or is interrupted" do
    for variation <- ActionTraces.variations() do
      info =
        WorkflowResultHelpers.step_trace_info(
          variation.attributes.step,
          variation.attributes.run_status
        )

      outcomes = Map.new(info.traces, &{&1["id"], &1["outcome"]})

      assert outcomes["search"] == "succeeded"
      assert outcomes["lookup"] == "succeeded"

      expected =
        case variation.id do
          :running -> "running"
          :completed -> "succeeded"
          :interrupted -> "unknown"
        end

      assert outcomes["download"] == expected
    end
  end
end
