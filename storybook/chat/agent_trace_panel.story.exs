defmodule Storybook.Chat.AgentTracePanel do
  use PhoenixStorybook.Story, :component

  def function, do: &ZaqWeb.Components.AgentTracePanel.agent_trace_panel/1

  def description,
    do:
      "Shared nested agent/workflow trace viewer; existing legacy chrome retained, token migration out of scope."

  def variations do
    root = %{
      "id" => "native.root",
      "type" => "tool_call",
      "name" => "search_knowledge_base",
      "outcome" => "succeeded",
      "duration_ms" => 32
    }

    child = child("translation", ["native.root", "a"], "native.root", "succeeded")
    grandchild = child("resource", ["native.root", "a", "b"], "translation", "failed")
    parallel = child("semantic", ["native.root", "c"], "native.root", "succeeded")
    unknown = child("interrupted", ["missing", "a"], "missing", "unknown")

    [
      %Variation{
        id: :nested_agent,
        description: "Siblings, grandchild failure and expanded input/result evidence",
        attributes: %{
          message_info: %{
            agent: "Answering Agent",
            model: "Local fake provider",
            measurements: %{tool_call_count: 1},
            traces: [root, child, grandchild, parallel]
          },
          expanded_ids: MapSet.new(["translation"]),
          toggle_event: "toggle_trace_details"
        }
      },
      %Variation{
        id: :workflow_children,
        description: "Selected step card is the root; no duplicate fake root Action",
        attributes: %{
          message_info: %{
            root_invocation_id: "native.root",
            traces: [child, grandchild, parallel]
          },
          show_summary: false,
          toggle_event: "toggle_trace_details"
        }
      },
      %Variation{
        id: :legacy_and_unattached,
        description: "Legacy flat entry beside interrupted, running and unattached evidence",
        attributes: %{
          message_info: %{
            traces: [
              %{"id" => "legacy", "type" => "content", "content" => "Legacy answer"},
              unknown,
              child("running", ["absent", "b"], "absent", "running")
            ]
          },
          toggle_event: "toggle_trace_details"
        }
      }
    ]
  end

  defp child(id, path, parent, outcome) do
    %{
      "id" => id,
      "type" => "tool_call",
      "name" => id,
      "origin" => "zaq_action",
      "invocation_path" => path,
      "parent_id" => parent,
      "outcome" => outcome,
      "arguments" => %{"query" => "example"},
      "response" => ["ok", %{"count" => 2}, []],
      "duration_ms" => 8
    }
  end
end
