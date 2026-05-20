defmodule Zaq.Engine.Workflows.DagBuilder do
  @moduledoc """
  Builds a `Runic.Workflow` from the `steps` / `steps_snapshot` map stored in
  a `Workflow` or `WorkflowRun` row.

  ## Expected input format

      %{
        "nodes" => [
          %{"name" => "fetch",  "type" => "action",
            "module" => "Zaq.Agent.Tools.Email.FetchEmails",
            "params" => %{}, "index" => 0},
          %{"name" => "draft",  "type" => "action",
            "module" => "Zaq.Agent.Tools.Email.DraftReply",
            "params" => %{}, "index" => 1}
        ],
        "edges" => [
          %{"from" => "fetch", "to" => "draft"},
          %{"from" => "fetch", "to" => "notify",
            "condition" => %{"field" => "count", "op" => "gt", "value" => 0},
            "mapping"   => %{"email_count" => "count"}}
        ]
      }

  Node types:
  - `"action"` / `"agent"` — wrapped in `Jido.Runic.ActionNode`, requires `"module"`.
    The module must satisfy the `Zaq.Engine.Workflows.Action` contract
    (`on_success/2`, `on_failure/2`, non-empty `schema/0` + `output_schema/0`);
    a non-conforming module fails the build with
    `{:error, {:contract_violation, module, missing}}`.

  Edge attributes (both optional):
  - `"condition"` — map with `"field"`, `"op"`, and optionally `"value"`. Supported
    ops: `eq`, `neq`, `gt`, `lt`, `gte`, `lte`, `not_empty`, `empty`, `in`. When
    present, an `EdgeStep` is injected between the two nodes; a false condition
    prunes the downstream branch (`ConditionNotMet` → `skip_downstream_subgraph`).
  - `"mapping"` — map of `target_key => source_key` string pairs. The EdgeStep
    renames upstream fact keys before delivering them to the downstream node.
    Source keys that appear in the mapping are consumed (not passed through).

  Plain `%{"from", "to"}`-only edges work exactly as before (no EdgeStep injected).

  Module resolution uses `Module.concat/1` guarded by `Code.ensure_loaded/1` — never
  `String.to_atom/1`.
  """

  alias Jido.Runic.ActionNode
  alias Zaq.Engine.Workflows.Action
  alias Zaq.Engine.Workflows.ActionWrapper
  alias Zaq.Engine.Workflows.EdgeCondition
  alias Zaq.Engine.Workflows.Steps.EdgeStep

  @type steps :: map()
  @type build_result :: {:ok, Runic.Workflow.t()} | {:error, term()}

  @spec build(steps(), keyword()) :: build_result()
  def build(steps, opts \\ [])

  def build(steps, opts) when is_map(steps) do
    run_id = Keyword.get(opts, :run_id)
    nodes_list = Map.get(steps, "nodes", [])
    edges_list = Map.get(steps, "edges", [])

    with :ok <- validate_keys(steps),
         :ok <- validate_non_empty(nodes_list),
         {:ok, node_map} <- build_node_map(nodes_list, run_id),
         :ok <- validate_edges(edges_list, node_map) do
      assemble(node_map, edges_list, run_id)
    end
  end

  def build(_, _), do: {:error, :invalid_steps}

  # --- Private ---

  defp validate_keys(steps) do
    if Map.has_key?(steps, "nodes") and Map.has_key?(steps, "edges") do
      :ok
    else
      {:error, :invalid_steps}
    end
  end

  defp validate_non_empty([]), do: {:error, :empty_dag}
  defp validate_non_empty(_), do: :ok

  defp build_node_map(nodes_list, run_id) do
    Enum.reduce_while(nodes_list, {:ok, %{}}, fn node, {:ok, acc} ->
      name = Map.get(node, "name")
      type = Map.get(node, "type")
      module = Map.get(node, "module")
      params = Map.get(node, "params", %{})
      index = Map.get(node, "index", 0)

      case build_node(type, module, params, name, index, run_id) do
        {:ok, runic_node} ->
          {:cont, {:ok, Map.put(acc, name, %{node: runic_node, index: index})}}

        {:error, _} = err ->
          {:halt, err}
      end
    end)
  end

  defp build_node(type, module, params, name, index, run_id)
       when type in ["action", "agent"] do
    with {:ok, mod} <- resolve_module(module),
         :ok <- Action.validate(mod) do
      {:ok, build_action_node(mod, atomize_keys(params), name, index, run_id)}
    end
  end

  defp build_node(type, _module, _params, _name, _index, _run_id),
    do: {:error, {:unknown_node_type, type}}

  defp resolve_module(nil), do: {:error, {:unknown_module, nil}}

  defp resolve_module(module_string) when is_binary(module_string) do
    mod = module_string |> String.split(".") |> Module.concat()

    case Code.ensure_loaded(mod) do
      {:module, _} -> {:ok, mod}
      {:error, _} -> {:error, {:unknown_module, module_string}}
    end
  end

  defp build_action_node(mod, params, name, step_index, run_id) when is_binary(run_id) do
    wrapper_params =
      Map.merge(params, %{
        wrapped_module: mod,
        run_id: run_id,
        step_name: name,
        step_index: step_index
      })

    ActionNode.new(ActionWrapper, wrapper_params, name: String.to_atom(name))
  end

  defp build_action_node(mod, params, name, _step_index, _run_id) do
    ActionNode.new(mod, params, name: String.to_atom(name))
  end

  defp validate_edges(edges, node_map) do
    Enum.reduce_while(edges, :ok, fn edge, :ok ->
      validate_single_edge(edge, node_map)
    end)
  end

  defp validate_single_edge(edge, node_map) do
    to = Map.get(edge, "to")

    if is_nil(to) or not Map.has_key?(node_map, to) do
      {:halt, {:error, {:unknown_node, to}}}
    else
      case validate_edge_condition(Map.get(edge, "condition")) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end
  end

  defp validate_edge_condition(nil), do: :ok

  defp validate_edge_condition(condition) when is_map(condition) do
    cs = EdgeCondition.changeset(condition)
    if cs.valid?, do: :ok, else: {:error, {:invalid_edge_condition, condition}}
  end

  defp validate_edge_condition(_), do: :ok

  defp assemble(node_map, edges, run_id) do
    workflow =
      node_map
      |> Enum.sort_by(fn {_name, %{index: i}} -> i end)
      |> Enum.reduce(Runic.Workflow.new(:workflow), fn {name, %{node: runic_node}}, wf ->
        incoming = Enum.filter(edges, &(Map.get(&1, "to") == name))
        add_node(wf, runic_node, name, incoming, node_map, run_id)
      end)

    {:ok, workflow}
  end

  defp add_node(workflow, runic_node, _to_name, [], _node_map, _run_id) do
    Runic.Workflow.add(workflow, runic_node)
  end

  defp add_node(workflow, runic_node, to_name, incoming, node_map, run_id) do
    Enum.reduce(incoming, workflow, fn edge, wf ->
      add_edge(wf, runic_node, to_name, edge, node_map, run_id)
    end)
  end

  defp add_edge(wf, runic_node, to_name, edge, node_map, run_id) do
    from_name = Map.get(edge, "from")
    condition = Map.get(edge, "condition")
    mapping = Map.get(edge, "mapping") || %{}

    if not is_nil(condition) or map_size(mapping) > 0 do
      guard_name = "#{from_name}__to__#{to_name}__edge"
      guard_node = build_edge_step_node(condition, mapping, guard_name, run_id)

      wf
      |> Runic.Workflow.add(guard_node, to: String.to_atom(from_name), validate: :off)
      |> Runic.Workflow.add(runic_node, to: String.to_atom(guard_name), validate: :off)
    else
      Runic.Workflow.add(wf, runic_node, direct_edge_opts(from_name, node_map))
    end
  end

  defp direct_edge_opts(from_name, node_map) do
    if from_name && Map.has_key?(node_map, from_name) do
      [to: String.to_atom(from_name), validate: :off]
    else
      [validate: :off]
    end
  end

  defp build_edge_step_node(condition, mapping, name, run_id) do
    params =
      %{__edge_condition__: condition, __edge_mapping__: mapping, __edge_name__: name}
      |> then(fn p -> if run_id, do: Map.put(p, :run_id, run_id), else: p end)

    ActionNode.new(EdgeStep, params, name: String.to_atom(name))
  end

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
      {k, v} -> {k, v}
    end)
  rescue
    ArgumentError -> map
  end

  defp atomize_keys(other), do: other
end
