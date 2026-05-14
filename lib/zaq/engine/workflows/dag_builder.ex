defmodule Zaq.Engine.Workflows.DagBuilder do
  @moduledoc """
  Builds a `Runic.Workflow` from the `steps` / `steps_snapshot` map stored in
  a `Workflow` or `WorkflowRun` row.

  ## Expected input format

      %{
        "nodes" => [
          %{"name" => "fetch", "type" => "action",
            "module" => "Zaq.Agent.Tools.Email.FetchEmails",
            "params" => %{}, "index" => 0},
          %{"name" => "emails_found", "type" => "condition",
            "params" => %{"field" => "count", "op" => "gt", "value" => 0}, "index" => 1},
          %{"name" => "no_emails", "type" => "condition",
            "params" => %{"field" => "count", "op" => "eq", "value" => 0}, "index" => 1}
        ],
        "edges" => [
          %{"from" => "fetch", "to" => "emails_found"},
          %{"from" => "fetch", "to" => "no_emails"},
          %{"from" => "emails_found", "to" => "draft"}
        ]
      }

  Node types:
  - `"action"` / `"agent"` — wrapped in `Jido.Runic.ActionNode`, requires `"module"`
  - `"condition"`           — a `FieldComparison` or custom Jido.Action that raises
    `ConditionNotMet` on false. Two forms:
    - **Inline** (preferred): omit `"module"`, use `"params"` with `"field"`, `"op"`, and
      optionally `"value"`. Supported ops: `eq`, `neq`, `gt`, `lt`, `gte`, `lte`,
      `not_empty`, `empty`, `in` (value must be a list).
    - **Module**: set `"module"` to a Jido.Action module that raises `ConditionNotMet`
      on false.

  Module resolution uses `Module.concat/1` guarded by `Code.ensure_loaded/1` — never
  `String.to_atom/1`.
  """

  alias Jido.Runic.ActionNode
  alias Zaq.Engine.Workflows.ActionWrapper
  alias Zaq.Engine.Workflows.Conditions.FieldComparison

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
      assemble(node_map, edges_list)
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

  # Inline condition — no module, default to FieldComparison with the given params
  defp build_node("condition", mod, params, name, index, run_id)
       when mod in [nil, ""] do
    {:ok, build_action_node(FieldComparison, atomize_keys(params), name, index, run_id)}
  end

  # Module-backed condition — must be a Jido.Action that raises ConditionNotMet on false
  defp build_node("condition", module, params, name, index, run_id) do
    with {:ok, mod} <- resolve_module(module) do
      {:ok, build_action_node(mod, atomize_keys(params), name, index, run_id)}
    end
  end

  defp build_node(type, module, params, name, index, run_id)
       when type in ["action", "agent"] do
    with {:ok, mod} <- resolve_module(module) do
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
      to = Map.get(edge, "to")

      if to && Map.has_key?(node_map, to) do
        {:cont, :ok}
      else
        {:halt, {:error, {:unknown_node, to}}}
      end
    end)
  end

  defp assemble(node_map, edges) do
    # Root nodes: those with no incoming edges
    all_targets = Enum.map(edges, &Map.get(&1, "to")) |> MapSet.new()

    workflow =
      node_map
      |> Enum.sort_by(fn {_name, %{index: i}} -> i end)
      |> Enum.reduce(Runic.Workflow.new(:workflow), fn {name, %{node: runic_node}}, wf ->
        incoming = Enum.filter(edges, &(Map.get(&1, "to") == name))

        if Enum.empty?(incoming) and MapSet.member?(all_targets, name) do
          # Node is referenced as a target but has no edges pointing to it — skip
          # (this shouldn't happen after validate_edges, but guard defensively)
          wf
        else
          add_node(wf, runic_node, incoming, node_map)
        end
      end)

    {:ok, workflow}
  end

  defp add_node(workflow, runic_node, [], _node_map) do
    Runic.Workflow.add(workflow, runic_node)
  end

  defp add_node(workflow, runic_node, incoming, node_map) do
    Enum.reduce(incoming, workflow, fn edge, wf ->
      from_name = Map.get(edge, "from")

      # Always skip static port validation — DagBuilder is a general-purpose
      # runtime assembler. Actions pass data through the live fact map, not
      # through statically declared port contracts.
      opts =
        if from_name && Map.has_key?(node_map, from_name) do
          [to: String.to_atom(from_name), validate: :off]
        else
          [validate: :off]
        end

      Runic.Workflow.add(wf, runic_node, opts)
    end)
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
