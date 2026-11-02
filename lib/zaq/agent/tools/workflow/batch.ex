defmodule Zaq.Agent.Tools.Workflow.Batch do
  @moduledoc """
  Build-time **translator**: rewrites a `Batch` node into the general `map`
  iteration primitive (see `Zaq.Engine.Workflows.DagBuilder` map lowering). Batch
  carries **no runtime loop** of its own — iteration, chunking, per-fork
  visibility, strategies, and error isolation all live in the `map` node.

  ## Translation

  A Batch node's `params` map onto a `map` node:

  - `process` ⇒ the map body (a flat pipeline of `action`/`agent` nodes). It is the
    work run for each fan-out unit.
  - `delivery` ⇒ how each unit reaches the body, lowered straight to the map's
    `delivery`:
    - `"list"` (default) — fan out **per chunk**; the body receives a chunk of up to
      `batch_size` items. Each chunk gets its own per-fork `StepRun`.
    - `"item"` — fan out **per item**; the body receives one item. Each item gets
      its own per-fork `StepRun`.
  - `batch_size` ⇒ the map's `chunk_size` (chunk width for `"list"`).
  - `strategy` ⇒ error strategy (default `"skip_and_continue"`).
  - `post_process` ⇒ the map's `post_process` (per-fork tail).
  - The delivery `field` (the param key the unit is delivered under) is detected
    from the body's first action's input schema.

  Iteration over the upstream collection always reads the `items` key (Batch's
  required input, supplied via the incoming edge mapping). Pipeline lowering is
  shared with `Iterate`; Batch retains scheduler-selected fork order. Use `Iterate`
  when each item must execute in input order.
  """

  @behaviour Zaq.Engine.Workflows.Node

  alias Zaq.Agent.Tools.Workflow.Iterate

  @impl true
  def enrich(node, _nodes) do
    params = Map.get(node, "params") || %{}

    with {:ok, lowered} <- Iterate.prepare_pipeline(node) do
      batch_params =
        lowered["params"]
        |> Map.put("ordered", false)
        |> Map.put("delivery", Map.get(params, "delivery", "list"))
        |> put_chunk_size(Map.get(params, "batch_size"))

      {:ok, Map.put(lowered, "params", batch_params)}
    end
  end

  @impl true
  def validate(node) do
    params = Map.get(node, "params") || %{}

    with :ok <- Iterate.validate(node),
         :ok <- validate_delivery(Map.get(params, "delivery", "list")) do
      validate_batch_size(Map.get(params, "batch_size"))
    end
  end

  defp validate_delivery(delivery) when delivery in ["item", "list"], do: :ok
  defp validate_delivery(_), do: {:error, ~s(delivery must be "item" or "list")}

  defp validate_batch_size(nil), do: :ok
  defp validate_batch_size(size) when is_integer(size) and size > 0, do: :ok
  defp validate_batch_size(_), do: {:error, "batch_size must be a positive integer"}

  defp put_chunk_size(params, nil), do: params
  defp put_chunk_size(params, size), do: Map.put(params, "chunk_size", size)
end
