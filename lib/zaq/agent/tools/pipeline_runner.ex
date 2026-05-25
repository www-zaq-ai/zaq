defmodule Zaq.Agent.Tools.PipelineRunner do
  @moduledoc false

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
