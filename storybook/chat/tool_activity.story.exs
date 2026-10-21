defmodule Storybook.Chat.ToolActivity do
  use PhoenixStorybook.Story, :component

  def function, do: &ZaqWeb.Components.ChatMessage.assistant_bubble/1
  def description, do: "Multiple ordered tool invocations in BO chat, shared by live delivery and authorized reload."

  def variations do
    for {id, state} <- [running: "running", succeeded: "succeeded", failed: "failed", unknown: "unknown"] do
      %Variation{
        id: id,
        attributes: %{
          content: if(state == "running", do: "", else: "Here is the answer based on the available knowledge."),
          timestamp: ~U[2026-10-20 10:00:00Z],
          tool_steps_id: "tool-activity-#{state}",
          tool_steps: steps(state)
        }
      }
    end
  end

  defp steps(scenario) do
    states =
      case scenario do
        "running" -> ~w(succeeded succeeded succeeded running)
        "succeeded" -> ~w(succeeded succeeded succeeded succeeded)
        "failed" -> ~w(succeeded failed succeeded failed)
        "unknown" -> ~w(succeeded succeeded unknown unknown)
      end

    [
      {"search", "Search knowledge base", 1200},
      {"read_document", "Read source document", 480},
      {"search", "Search related topics", 750},
      {"read_document", "Read supporting document", 320}
    ]
    |> Enum.zip(states)
    |> Enum.with_index(1)
    |> Enum.map(fn {{{name, label, duration}, state}, sequence} ->
      step = %{"id" => "#{name}-#{sequence}", "kind" => "tool", "name" => name,
        "label" => label, "sequence" => sequence, "state" => state}

      if state in ["succeeded", "failed"], do: Map.put(step, "duration_ms", duration), else: step
    end)
  end
end
