defmodule Zaq.Engine.Workflows.Steps.MapCollect do
  @moduledoc """
  Internal tail step for a `"map"` node (see `DagBuilder`).

  Runs once, after the map's `reduce`/`FanIn` has collected every **successful**
  per-item result. Wrapped by `StepRunner` under the **map node's own name**, so it
  writes the single **aggregate `StepRun`** for the map.

  Output (`%{"results" => [...], "errors" => [...], "count" => n}`):

  - `results` — the successful items' collected results (from the FanIn, in
    `params.input`).
  - `errors` — one entry per **failed** fork, read back from the per-fork `StepRun`
    rows (`<map>/<step>[i]`): `%{"index" => i, "item" => <identity>, "reason" => …}`
    (decision (b): reason + a small item identity, not the full payload).

  Failed forks never reach the FanIn (their fact errors out), so their failures are
  recovered from their own `StepRun` rows — which is also what gives the user
  per-item error visibility in the run graph.
  """

  use Jido.Action, name: "workflow_map_collect", schema: []

  alias Zaq.Engine.Workflows

  @impl true
  def run(params, context) do
    results =
      case Map.get(params, :input) || Map.get(params, "input") do
        list when is_list(list) -> list
        _ -> []
      end

    errors = collect_errors(Map.get(context || %{}, :run_id), prefix(params))

    {:ok,
     %{"results" => results, "errors" => errors, "count" => length(results) + length(errors)}}
  end

  defp prefix(params), do: Map.get(params, :__map_prefix__) || Map.get(params, "__map_prefix__")

  defp collect_errors(nil, _prefix), do: []
  defp collect_errors(_run_id, nil), do: []

  defp collect_errors(run_id, prefix) do
    run_id
    |> Workflows.list_step_runs()
    |> Enum.filter(&(&1.status in ["failed", "failed_fatal"] and fork_of?(&1.step_name, prefix)))
    |> Enum.map(fn step_run ->
      %{
        "index" => fork_index(step_run.step_name),
        "item" => identity(step_run.input),
        "reason" => reason(step_run.errors)
      }
    end)
    |> Enum.sort_by(& &1["index"])
  end

  # A body fork row is named "<prefix><step>[i]".
  defp fork_of?(name, prefix), do: String.starts_with?(name, prefix) and fork_index(name) != nil

  defp fork_index(name) do
    case Regex.run(~r/\[(\d+)\]$/, name) do
      [_, i] -> String.to_integer(i)
      _ -> nil
    end
  end

  # Decision (b): keep a small item identity, not the full payload. The fork's
  # stored `input` is already just the item's own fields (wrapper keys stripped).
  defp identity(input) when is_map(input), do: input
  defp identity(other), do: other

  defp reason(errors) when is_map(errors),
    do: Map.get(errors, "reason") || Map.get(errors, :reason)

  defp reason(other), do: other
end
