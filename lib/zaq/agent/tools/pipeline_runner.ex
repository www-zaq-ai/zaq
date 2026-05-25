defmodule Zaq.Agent.Tools.PipelineRunner do
  @moduledoc false

  @max_retries 3

  def finalize_result({:error, _} = err), do: err

  def finalize_result({results, errors, logs}) do
    {:ok,
     %{results: Enum.reverse(results), errors: Enum.reverse(errors), logs: Enum.reverse(logs)}}
  end

  def invoke(delivery, pipeline, :retry, context),
    do: invoke_with_retry(delivery, pipeline, context, @max_retries)

  def invoke(delivery, pipeline, _strategy, context),
    do: run_pipeline(delivery, pipeline, context)

  defp invoke_with_retry(delivery, pipeline, context, retries_left) do
    case run_pipeline(delivery, pipeline, context) do
      {:ok, value} ->
        {:ok, value}

      {:error, _} when retries_left > 1 ->
        invoke_with_retry(delivery, pipeline, context, retries_left - 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  def run_pipeline(delivery, [], _context), do: {:ok, delivery}

  def run_pipeline(delivery, pipeline, context) do
    Enum.reduce_while(pipeline, {:ok, delivery}, fn {mod, base_params}, {:ok, acc} ->
      case mod.run(Map.merge(base_params, acc), context) do
        {:ok, result} -> {:cont, {:ok, result}}
        {:ok, result, _logs} -> {:cont, {:ok, result}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end
end
