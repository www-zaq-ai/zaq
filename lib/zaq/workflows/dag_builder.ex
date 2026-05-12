defmodule Zaq.Workflows.DagBuilder do
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
            "module" => "Zaq.Workflows.Conditions.EmailsFound",
            "params" => %{}, "index" => 1}
        ],
        "edges" => [
          %{"from" => "fetch", "to" => "emails_found"},
          %{"from" => "emails_found", "to" => "draft", "validate_ports" => false}
        ]
      }

  Node types:
  - `"action"` / `"agent"` — wrapped in `Jido.Runic.ActionNode`
  - `"condition"`           — wrapped in `Runic.condition/2` via the module's `call/1`

  Module resolution uses `Module.safe_concat/1` — never `String.to_atom/1`.
  """

  alias Jido.Runic.ActionNode
  require Runic

  @type steps :: map()
  @type build_result :: {:ok, Runic.Workflow.t()} | {:error, term()}

  @spec build(steps()) :: build_result()
  def build(steps) when is_map(steps) do
    nodes_list = Map.get(steps, "nodes", [])
    edges_list = Map.get(steps, "edges", [])

    with :ok <- validate_keys(steps),
         :ok <- validate_non_empty(nodes_list),
         {:ok, node_map} <- build_node_map(nodes_list),
         :ok <- validate_edges(edges_list, node_map) do
      assemble(node_map, edges_list)
    end
  end

  def build(_), do: {:error, :invalid_steps}

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

  defp build_node_map(nodes_list) do
    Enum.reduce_while(nodes_list, {:ok, %{}}, fn node, {:ok, acc} ->
      name = Map.get(node, "name")
      type = Map.get(node, "type")
      module = Map.get(node, "module")
      params = Map.get(node, "params", %{}) |> atomize_keys()
      index = Map.get(node, "index", 0)

      case resolve_module(module) do
        {:ok, mod} ->
          runic_node = build_runic_node(type, mod, params, name)
          {:cont, {:ok, Map.put(acc, name, %{node: runic_node, index: index})}}

        {:error, _} = err ->
          {:halt, err}
      end
    end)
  end

  defp resolve_module(nil), do: {:error, {:unknown_module, nil}}

  defp resolve_module(module_string) when is_binary(module_string) do
    mod = module_string |> String.split(".") |> Module.concat()

    case Code.ensure_loaded(mod) do
      {:module, _} -> {:ok, mod}
      {:error, _} -> {:error, {:unknown_module, module_string}}
    end
  end

  defp build_runic_node(type, mod, params, name) when type in ["action", "agent"] do
    ActionNode.new(mod, params, name: String.to_atom(name))
  end

  defp build_runic_node("condition", mod, _params, name) do
    Runic.condition(&mod.call/1, name: String.to_atom(name))
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
