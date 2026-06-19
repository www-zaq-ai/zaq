defmodule Zaq.Agent.Tools.PipelineRunner do
  @moduledoc """
  Runs the inline action pipelines embedded inside workflow orchestration tools.

  `Batch` and `Iterate` are not ordinary single-step actions: each receives a
  resolved list of `{module, base_params}` tuples from `DagBuilder` and must run
  that list for a chunk or item while preserving the workflow action contract.
  This module owns that shared inner loop so both tools apply the same behavior:

  - merge the current delivery payload into each step's base params before
    calling `run/2`;
  - pass through the workflow context unchanged;
  - stop at the first `{:error, reason}`;
  - treat `{:ok, result}` and `{:ok, result, logs: logs}` as successful steps;
  - optionally retry the whole inline pipeline for `:retry` strategy;
  - call an optional `on_step` callback so callers can broadcast per-step
    progress; and
  - normalize accumulated batch/iterate results through `finalize_result/1`.

  It is intentionally narrower than the main workflow DAG executor. It does not
  build DAGs, evaluate edge conditions, persist step runs, or dispatch events.
  It only executes already-resolved linear sub-pipelines used inside
  orchestration actions.
  """

  @max_retries 3

  def finalize_result({:error, _} = err), do: err

  def finalize_result({results, errors, logs}) do
    {:ok,
     %{results: Enum.reverse(results), errors: Enum.reverse(errors), logs: Enum.reverse(logs)}}
  end

  def invoke(delivery, pipeline, strategy, context, on_step \\ nil)

  def invoke(delivery, pipeline, :retry, context, on_step),
    do: invoke_with_retry(delivery, pipeline, context, @max_retries, on_step)

  def invoke(delivery, pipeline, _strategy, context, on_step),
    do: run_pipeline(delivery, pipeline, context, on_step)

  defp invoke_with_retry(delivery, pipeline, context, retries_left, on_step) do
    case run_pipeline(delivery, pipeline, context, on_step) do
      {:ok, value} ->
        {:ok, value}

      {:error, _} when retries_left > 1 ->
        invoke_with_retry(delivery, pipeline, context, retries_left - 1, on_step)

      {:error, reason} ->
        {:error, reason}
    end
  end

  def run_pipeline(delivery, pipeline, context, on_step \\ nil)

  def run_pipeline(delivery, [], _context, _on_step), do: {:ok, delivery}

  def run_pipeline(delivery, pipeline, context, on_step) do
    pipeline
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, delivery}, fn {{mod, base_params}, step_idx}, {:ok, acc} ->
      on_step && on_step.(step_idx)
      handle_step_result(mod.run(Map.merge(base_params, acc), context))
    end)
  end

  def handle_step_result({:ok, result}), do: {:cont, {:ok, result}}
  def handle_step_result({:ok, result, _logs}), do: {:cont, {:ok, result}}
  def handle_step_result({:error, _} = err), do: {:halt, err}
end
