defmodule Zaq.Agent.Tools.Workflow.Batch do
  @moduledoc """
  Build-time **translator**: rewrites a `Batch` node into the general `map`
  iteration primitive (see `Zaq.Engine.Workflows.DagBuilder` map lowering). Batch
  carries **no runtime loop** of its own — iteration, chunking, per-fork
  visibility, strategies, and error isolation all live in the `map` node.

  ## Translation

  A Batch node's `params` are mapped onto a `map` node:

  - `process == [<single Iterate node>]` ⇒ the Iterate is unwrapped: the map body
    is the Iterate's `pipeline`, delivered **per item** (`delivery: "item"`).
    `batch_size` becomes a throughput hint (`chunk_size`); fan-out stays per item so
    each item gets its own `StepRun` (the visibility upgrade). The inner Iterate's
    `strategy` wins.
  - `process == [<plain pipeline>]` ⇒ the map body is the process pipeline,
    delivered **per chunk** (`delivery: "list"`, `chunk_size: batch_size`); the
    body's first action's input schema decides the delivery `field`/mode.
  - `post_process` ⇒ the map's `post_process` (per-fork tail).

  Iteration over the upstream collection always reads the `items` key (Batch's
  required input, supplied via the incoming edge mapping). `Iterate` no longer
  exists as a runtime module — it survives only as the inline marker this
  translator unwraps.
  """

  @behaviour Zaq.Engine.Workflows.Node

  alias Zaq.Engine.Workflows.Action

  @iterate_module "Zaq.Agent.Tools.Workflow.Iterate"

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
    batch_strategy = Map.get(params, "strategy", "skip_and_continue")

    with {:ok, body, delivery, strategy} <- resolve_body(process, batch_strategy),
         {:ok, field} <- detect_field(body) do
      map_params =
        %{
          "over" => "items",
          "body" => body,
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

  # A nested Iterate ⇒ per-item fan-out over the Iterate's pipeline.
  defp resolve_body([%{"module" => @iterate_module} = iter], batch_strategy) do
    iter_params = Map.get(iter, "params") || %{}
    pipeline = Map.get(iter_params, "pipeline", [])
    strategy = Map.get(iter_params, "strategy", batch_strategy)

    if pipeline == [] do
      {:error, {:missing_iterate_pipeline, Map.get(iter, "name")}}
    else
      {:ok, pipeline, "item", strategy}
    end
  end

  # A plain process pipeline ⇒ per-chunk fan-out over the pipeline.
  defp resolve_body([_ | _] = process, batch_strategy),
    do: {:ok, process, "list", batch_strategy}

  defp resolve_body(_empty, _batch_strategy), do: {:error, :missing_process_pipeline}

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
