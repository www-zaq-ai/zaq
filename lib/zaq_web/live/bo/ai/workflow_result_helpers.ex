defmodule ZaqWeb.Live.BO.AI.WorkflowResultHelpers do
  @moduledoc false

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
end
