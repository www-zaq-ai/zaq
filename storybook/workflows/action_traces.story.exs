defmodule Storybook.Workflows.ActionTracesPreview do
  use Phoenix.Component

  alias ZaqWeb.Live.BO.AI.WorkflowComponents

  attr :step, :map, required: true
  attr :run_status, :string, required: true
  attr :expanded_trace_ids, :map, default: %{}

  def step_card_preview(assigns) do
    ~H"""
    <ZaqWeb.Components.DesignSystem.CardShell.card_shell id={"preview-step-#{@step.id}"}>
      <:header>
        <p class="zaq-text-body-sm">Selected workflow step · parent of the Action calls below</p>
        <div class="zaq-layout-inline flex-wrap">
          <h3 class="zaq-text-h4">{@step.step_index + 1}. {@step.step_name}</h3>
          <WorkflowComponents.run_status_badge status={@step.status} />
          <WorkflowComponents.run_duration run={@step} now={~U[2026-11-06 12:00:01Z]} />
        </div>
      </:header>
      <div class="zaq-layout-stack">
        <details>
          <summary class="zaq-text-body-sm">Input</summary>
          <ZaqWeb.Components.JsonTree.json_tree
            id={"preview-step-input-#{@step.id}"}
            data={@step.input}
          />
        </details>
        <WorkflowComponents.step_action_traces
          step={@step}
          run_status={@run_status}
          expanded_trace_ids={@expanded_trace_ids}
        />
      </div>
    </ZaqWeb.Components.DesignSystem.CardShell.card_shell>
    """
  end
end

defmodule Storybook.Workflows.ActionTraces do
  use PhoenixStorybook.Story, :component

  def function, do: &Storybook.Workflows.ActionTracesPreview.step_card_preview/1

  def layout, do: :one_column
  def container, do: :iframe

  def description,
    do:
      "Selected workflow step context around the production Action trace viewer. " <>
        "Review documents is the step root: Search knowledge base calls Get document, " <>
        "while Download document is a sibling. Fixtures only; no workflow is executed."

  def variations do
    root = "workflow_step:review-step"
    search = started("search", "search_knowledge_base", [root, "a"], root, %{"query" => "guide"})
    lookup =
      started("lookup", "get_document", [root, "a", "b"], "search", %{"document_id" => "guide.md"})

    download =
      started("download", "download_document", [root, "c"], root, %{"document_id" => "appendix.md"})
    lookup_done = completed(lookup, 3, %{"name" => "guide.md"})
    search_done = completed(search, 4, %{"documents" => ["guide.md"]})
    events = [search, lookup, download, lookup_done, search_done]

    step = %{
      id: "review-step",
      step_name: "Review documents",
      step_index: 0,
      status: "running",
      started_at: ~U[2026-11-06 12:00:00Z],
      finished_at: nil,
      input: %{"query" => "guide", "attachments" => ["appendix.md"]},
      trace_events: events
    }

    [
      %Variation{
        id: :running,
        description:
          "Step → Search knowledge base → Get document; sibling Download document is still running",
        attributes: %{
          step: step,
          run_status: "running",
          expanded_trace_ids: %{"review-step" => MapSet.new(["lookup"])}
        }
      },
      %Variation{
        id: :completed,
        description: "Completed step with a successful child, grandchild and sibling",
        attributes: %{
          step: %{
            step
            | status: "completed",
              finished_at: ~U[2026-11-06 12:00:01Z],
              trace_events: events ++ [completed(download, 6, %{"name" => "appendix.md"})]
          },
          run_status: "completed"
        }
      },
      %Variation{
        id: :interrupted,
        description:
          "Interruption leaves an unresolved sibling unknown; successful evidence is retained",
        attributes: %{
          step: %{step | status: "interrupted", finished_at: ~U[2026-11-06 12:00:01Z]},
          run_status: "interrupted"
        }
      }
    ]
  end

  defp started(id, name, path, parent, arguments) do
    %{
      "id" => "#{id}-start",
      "kind" => "tool_started",
      "tool_call_id" => id,
      "tool_name" => name,
      "at_ms" => 1,
      "data" => %{
        "origin" => "zaq_action",
        "invocation_path" => path,
        "parent_id" => parent,
        "arguments" => arguments
      }
    }
  end

  defp completed(event, at_ms, result) do
    %{
      event
      | "id" => "#{event["tool_call_id"]}-done",
        "kind" => "tool_completed",
        "at_ms" => at_ms,
        "data" =>
          Map.merge(event["data"], %{
            "outcome" => "succeeded",
            "result" => ["ok", result, []],
            "duration_ms" => at_ms - event["at_ms"]
          })
    }
  end
end
