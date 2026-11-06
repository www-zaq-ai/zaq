defmodule ZaqWeb.Live.BO.AI.WorkflowResultHelpers do
  @moduledoc """
  Pure presentation adapters for workflow results and persisted child evidence.

  Step trace projection groups already-recorded lifecycle facts by invocation ID;
  it neither interprets Agent streams nor executes/settles workflow business state.
  """

  @trace_keys ["trace", :trace, "agent", :agent, "model", :model, "measurements", :measurements]

  def clean_results(nil), do: %{}

  def clean_results(results) when is_map(results) do
    results
    |> Map.drop(["__cascade__", :__cascade__] ++ @trace_keys)
    |> Enum.reject(fn {_k, v} -> is_map(v) and Map.has_key?(v, "__cascade__") end)
    |> Map.new()
  end

  @doc """
  Shapes a `Step.Run.results` map into the `%{agent:, model:, measurements:,
  traces:}` shape `ZaqWeb.Components.AgentTracePanel.agent_trace_panel/1` expects.

  Deliberately self-contained rather than routed through
  `ZaqWeb.Live.BO.Communication.MessageHelpers.message_info_from_runtime/1` —
  that function unconditionally injects `prompt_tokens`/`completion_tokens`/
  `total_tokens` "not provided" placeholders (chat-specific UX), which would
  make `agent_trace_available?/1` return true for every step with any results
  map at all, not just steps that actually ran an agent.
  """
  def agent_trace_info(results) when is_map(results) do
    %{
      agent: Map.get(results, "agent") || Map.get(results, :agent),
      model: Map.get(results, "model") || Map.get(results, :model),
      measurements: Map.get(results, "measurements") || Map.get(results, :measurements) || %{},
      traces: Map.get(results, "trace") || Map.get(results, :trace) || []
    }
  end

  def agent_trace_info(_), do: %{agent: nil, model: nil, measurements: %{}, traces: []}

  @doc "True when `results` carries any agent/model/measurement/trace data to show."
  def agent_trace_available?(results) do
    info = agent_trace_info(results)

    info.agent not in [nil, %{}] or info.model not in [nil, ""] or
      info.traces != [] or map_size(info.measurements) > 0
  end

  @doc "Projects persisted step child events into the shared trace-row shape."
  def step_trace_info(step, run_status \\ nil) do
    events = Map.get(step, :trace_events) || []

    terminal =
      step.status in ~w(completed failed failed_fatal skipped cancelled interrupted paused) or
        run_status in ~w(completed failed incomplete cancelled interrupted paused)

    traces =
      events
      |> Enum.reduce(%{}, &project_step_event/2)
      |> Map.values()
      |> Enum.map(fn
        %{"outcome" => "running"} = row when terminal -> Map.put(row, "outcome", "unknown")
        row -> row
      end)
      |> Enum.sort_by(& &1["sequence"])

    root = if id = Map.get(step, :id), do: "workflow_step:#{id}"
    %{root_invocation_id: root, agent: nil, model: nil, measurements: %{}, traces: traces}
  end

  defp project_step_event(
         %{"tool_call_id" => id, "kind" => kind, "data" => %{"origin" => "zaq_action"} = data} =
           event,
         rows
       )
       when is_binary(id) and kind in ["tool_started", "tool_completed"] do
    existing = Map.get(rows, id, %{})

    base = %{
      "id" => id,
      "invocation_id" => id,
      "type" => "tool_call",
      "name" => event["tool_name"],
      "content" => event["tool_name"],
      "origin" => "zaq_action",
      "invocation_path" => data["invocation_path"],
      "parent_id" => data["parent_id"],
      "sequence" => Map.get(existing, "sequence", map_size(rows) + 1)
    }

    Map.put(rows, id, project_step_lifecycle(kind, base, existing, event))
  end

  defp project_step_event(_event, rows), do: rows

  defp project_step_lifecycle("tool_started", base, existing, event) do
    base
    |> Map.merge(%{
      "arguments" => event["data"]["arguments"],
      "started_at_ms" => event["at_ms"],
      "status" => "started",
      "outcome" => "running"
    })
    |> Map.merge(existing)
  end

  defp project_step_lifecycle(
         "tool_completed",
         base,
         %{"status" => "completed"} = existing,
         _event
       ),
       do: Map.merge(base, existing)

  defp project_step_lifecycle("tool_completed", base, existing, event) do
    data = event["data"]

    outcome =
      if data["outcome"] in ~w(succeeded failed unknown), do: data["outcome"], else: "unknown"

    existing
    |> Map.merge(base)
    |> Map.merge(%{
      "response" => data["result"],
      "duration_ms" => data["duration_ms"],
      "ended_at_ms" => event["at_ms"],
      "status" => "completed",
      "outcome" => outcome
    })
  end
end
