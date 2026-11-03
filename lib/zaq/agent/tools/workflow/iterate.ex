defmodule Zaq.Agent.Tools.Workflow.Iterate do
  @moduledoc """
  Runs an inline workflow pipeline once per item, in input order.

  Authored as an action node, this translator lowers to the engine's internal
  map primitive. Each item's `process` and `post_process` finish before the next
  item starts. Incoming `items` are delivered under the first action's input
  field. Body mappings use the workflow cascade; outputs are collected as
  `results`, `errors`, and `count`. StepRunner owns persistence and retries.
  """

  @behaviour Zaq.Engine.Workflows.Node

  alias Zaq.Engine.Workflows.Action
  alias Zaq.Engine.Workflows.Step

  @impl true
  def enrich(node, _nodes) do
    with {:ok, prepared} <- prepare_pipeline(node) do
      params = Map.merge(prepared["params"], %{"ordered" => true, "delivery" => "item"})
      {:ok, Map.put(prepared, "params", params)}
    end
  end

  @doc """
  Prepares the shared inline pipeline for Iterate and Batch without choosing
  execution order, delivery mode, or chunking.
  """
  @spec prepare_pipeline(map()) :: {:ok, map()} | {:error, term()}
  def prepare_pipeline(node) do
    params = Map.get(node, "params") || %{}
    name = Map.get(node, "name")
    process = Map.get(params, "process", [])
    post_process = Map.get(params, "post_process", [])
    strategy = Map.get(params, "strategy", "skip_and_continue")

    with :ok <- require_process(process),
         {:ok, field} <- detect_field(process) do
      map_params =
        %{
          "over" => "items",
          "body" => process,
          "field" => field,
          "strategy" => strategy,
          "post_process" => post_process
        }

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

  @impl true
  def validate(node) do
    with {:ok, %{"params" => params}} <- prepare_pipeline(node),
         :ok <- validate_pipeline(params["body"], "process") do
      validate_pipeline(params["post_process"] || [], "post_process")
    end
  end

  # Each lowered body node is validated through the single node validator
  # (`Step.Node.validate_node_map/1`) — the same rules a top-level node gets, with
  # no Batch-specific re-derivation of type/module/contract checks.
  defp validate_pipeline(nodes, pipeline) when is_list(nodes) do
    nodes
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {bnode, i}, :ok ->
      case Step.Node.validate_node_map(bnode) do
        :ok -> {:cont, :ok}
        {:error, msg} -> {:halt, {:error, "#{pipeline} node #{i}: #{msg}"}}
      end
    end)
  end

  defp validate_pipeline(_nodes, pipeline), do: {:error, "#{pipeline} must be a list of nodes"}

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
end
