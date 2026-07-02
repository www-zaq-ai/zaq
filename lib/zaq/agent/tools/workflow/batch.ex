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
  required input, supplied via the incoming edge mapping). There is no `Iterate`
  module — delivery mode is the explicit `delivery` param, not a wrapper node.
  """

  @behaviour Zaq.Engine.Workflows.Node

  alias Zaq.Engine.Workflows.Action
  alias Zaq.Engine.Workflows.Step

  @default_delivery "list"

  @doc """
  Rewrites a Batch node into a `map` node. Returns `{:ok, map_node}` or
  `{:error, reason}` when the process pipeline is missing/unresolvable.
  """
  @impl Zaq.Engine.Workflows.Node
  def enrich(node, _nodes_list) do
    params = Map.get(node, "params") || %{}
    name = Map.get(node, "name")
    process = Map.get(params, "process", [])
    post_process = Map.get(params, "post_process", [])
    batch_size = Map.get(params, "batch_size")
    strategy = Map.get(params, "strategy", "skip_and_continue")
    delivery = Map.get(params, "delivery", @default_delivery)

    with :ok <- require_process(process),
         {:ok, field} <- detect_field(process) do
      map_params =
        %{
          "over" => "items",
          "body" => process,
          "field" => field,
          "delivery" => delivery,
          "strategy" => strategy,
          "post_process" => post_process
        }
        |> maybe_put("chunk_size", batch_size)

      {:ok,
       %{
         "name" => name,
         "type" => "map",
         "index" => Map.get(node, "index"),
         "params" => map_params
       }}
    end
  end

  defp require_process([_ | _]), do: :ok
  defp require_process(_), do: {:error, :missing_process_pipeline}

  @doc """
  Save-time validation for an authored Batch node (dispatched by
  `Zaq.Engine.Workflows.Step.Node`). Lowers the node via `enrich/2` and validates
  the resulting iteration body — every body node must satisfy the
  `Workflows.Action` contract, and `batch_size` (carried as `chunk_size`) must be a
  positive integer when present. This gives a Batch node the same save-time
  guarantees the retired public `map` type used to enforce directly.
  """
  @impl Zaq.Engine.Workflows.Node
  def validate(node) do
    case enrich(node, []) do
      {:ok, %{"params" => params}} -> validate_map_params(params)
      {:error, _reason} = err -> err
    end
  end

  defp validate_map_params(params) do
    with :ok <- validate_body(Map.get(params, "body")),
         :ok <- validate_delivery(Map.get(params, "delivery")) do
      validate_chunk_size(Map.get(params, "chunk_size"))
    end
  end

  defp validate_delivery(d) when d in ["item", "list"], do: :ok
  defp validate_delivery(_), do: {:error, ~s(delivery must be "item" or "list")}

  # Each lowered body node is validated through the single node validator
  # (`Step.Node.validate_node_map/1`) — the same rules a top-level node gets, with
  # no Batch-specific re-derivation of type/module/contract checks.
  defp validate_body([_ | _] = body) do
    body
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {bnode, i}, :ok ->
      case Step.Node.validate_node_map(bnode) do
        :ok -> {:cont, :ok}
        {:error, msg} -> {:halt, {:error, "process node #{i}: #{msg}"}}
      end
    end)
  end

  defp validate_body(_body), do: {:error, "process must list at least one node"}

  defp validate_chunk_size(nil), do: :ok
  defp validate_chunk_size(n) when is_integer(n) and n > 0, do: :ok
  defp validate_chunk_size(_n), do: {:error, "batch_size must be a positive integer"}

  # Delivery field comes from the body's first action's input schema.
  # `Action.batch_field/1` guards module loading, so we only need the atom here.
  defp detect_field([%{"module" => module} | _]) when is_binary(module) do
    mod = module |> String.split(".") |> Module.concat()

    case Action.batch_field(mod) do
      {:ok, {field, _mode}} -> {:ok, to_string(field)}
      {:error, _} = err -> err
    end
  end

  defp detect_field(_), do: {:error, :missing_process_pipeline}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
