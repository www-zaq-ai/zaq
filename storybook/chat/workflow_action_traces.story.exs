defmodule Storybook.Chat.WorkflowActionTraces do
  use PhoenixStorybook.Story, :component

  def function, do: &ZaqWeb.Live.BO.AI.WorkflowComponents.step_action_traces/1

  def description,
    do:
      "Production workflow trace projection from persisted events, beneath the existing step card."

  def variations do
    root = "workflow_step:review-step"

    child = %{
      "id" => "lookup-start",
      "kind" => "tool_started",
      "tool_call_id" => "lookup",
      "tool_name" => "get_document",
      "at_ms" => 1,
      "data" => %{
        "origin" => "zaq_action",
        "invocation_path" => [root, "a"],
        "parent_id" => root,
        "arguments" => %{"document_id" => "guide.md"}
      }
    }

    completed = %{
      child
      | "id" => "lookup-done",
        "kind" => "tool_completed",
        "at_ms" => 3,
        "data" =>
          Map.merge(child["data"], %{
            "outcome" => "succeeded",
            "result" => ["ok", %{"name" => "guide.md"}, []],
            "duration_ms" => 2
          })
    }

    pending = %{
      child
      | "id" => "pending-start",
        "tool_call_id" => "pending",
        "tool_name" => "download_document",
        "data" => %{child["data"] | "invocation_path" => [root, "b"]}
    }

    step = %{id: "review-step", status: "running", trace_events: [child, completed, pending]}

    [
      %Variation{
        id: :running,
        description: "Recorded success remains known while a sibling is running",
        attributes: %{
          step: step,
          run_status: "running",
          expanded_trace_ids: %{"review-step" => MapSet.new(["lookup"])}
        }
      },
      %Variation{
        id: :interrupted,
        description:
          "Interruption leaves an unresolved sibling unknown; successful evidence is retained",
        attributes: %{
          step: %{step | status: "failed"},
          run_status: "failed"
        }
      }
    ]
  end
end
