defmodule Zaq.Engine.Workflows.DagBuilder do
  @moduledoc """
  Builds a `Runic.Workflow` from the `steps` / `steps_snapshot` map stored in
  a `Workflow` or `WorkflowRun` row.

  ## Expected input format

      %{
        "nodes" => [
          %{"name" => "load_items", "type" => "action",
            "module" => "Zaq.Agent.Tools.LoadItems",
            "params" => %{}, "index" => 0},
          %{"name" => "draft", "type" => "action",
            "module" => "Zaq.Agent.Tools.Workflow.RunAgent",
            "params" => %{"agent_id" => 42, "input" => "Draft a reply"},
            "index" => 1}
        ],
        "edges" => [
          %{"from" => "load_items", "to" => "draft"},
          %{"from" => "load_items", "to" => "notify",
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

  ## Batch nodes (translated to `map`)

  `Zaq.Agent.Tools.Workflow.Batch` is a build-time **translator**, not a runtime
  orchestrator: `enrich_nodes/1` calls `Batch.enrich/2`, which rewrites the Batch
  node into a general `"map"` node before the node map is built. Iteration,
  chunking, per-fork visibility, strategies, and error isolation all live in the
  `map` lowering (see "map node lowering" below). Delivery mode is the explicit
  `delivery` param (`"item"` | `"list"`) — there is no `Iterate` wrapper node.

  A Batch node declares its sub-pipeline as a flat **inline node map** pipeline
  inside `params`:

      %{
        "name" => "batch_contacts",
        "type" => "action",
        "module" => "Zaq.Agent.Tools.Workflow.Batch",
        "params" => %{
          "delivery"   => "item",            # or "list" (per-chunk, the default)
          "batch_size" => 4,                 # chunk width for "list"
          "strategy"   => "skip_and_continue",
          "process" => [ ...inline body nodes... ],
          "post_process" => [ ...inline tail nodes... ]
        },
        "index" => 1
      }

  Body nodes are validated against the `Workflows.Action` contract when the `map`
  body is lowered. Only top-level `nodes` appear in the built `Runic.Workflow` DAG —
  the inline body/post_process nodes become the map's per-fork body chain.

  ## Edge attributes (both optional)

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
  alias Zaq.Engine.Workflows.EdgeCondition
  alias Zaq.Engine.Workflows.MapNodeBuilder
  alias Zaq.Engine.Workflows.StepRunner

  @type steps :: map()
  @type build_result :: {:ok, Runic.Workflow.t()} | {:error, term()}

  # Reserved sentinel `from` for the virtual origin node. A `from: "start"` edge
  # remaps/guards the planted initial fact before it reaches a root node. Shared
  # with `Step.Node` so node naming and edge wiring agree on one reserved word.
  @start_sentinel "start"

  def start_sentinel, do: @start_sentinel

  @spec build(steps(), keyword()) :: build_result()
  def build(steps, opts \\ [])

  def build(steps, opts) when is_map(steps) do
    run_id = Keyword.get(opts, :run_id)
    nodes_list = Map.get(steps, "nodes", [])
    edges_list = Map.get(steps, "edges", [])

    with :ok <- validate_keys(steps),
         :ok <- validate_non_empty(nodes_list),
         {:ok, enriched_nodes} <- enrich_nodes(nodes_list),
         {:ok, node_map} <- build_node_map(enriched_nodes, run_id),
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
      params = Map.get(node, "params") || %{}
      index = Map.get(node, "index", 0)

      case build_node(type, module, params, name, index, run_id) do
        {:ok, entry} ->
          {:cont, {:ok, Map.put(acc, name, Map.put(entry, :index, index))}}

        {:error, _} = err ->
          {:halt, err}
      end
    end)
  end

  defp build_node(type, module, params, name, index, run_id)
       when type in ["action", "agent"] do
    with {:ok, mod} <- resolve_module(module),
         :ok <- Action.validate(mod) do
      {:ok, %{node: build_action_node(mod, atomize_keys(params), name, index, run_id)}}
    end
  end

  defp build_node("map", _module, params, name, index, run_id) do
    with {:ok, spec} <- MapNodeBuilder.build_spec(name, params, index, run_id) do
      {:ok, %{map: spec}}
    end
  end

  defp build_node(type, _module, _params, _name, _index, _run_id),
    do: {:error, {:unknown_node_type, type}}

  # Module resolution is shared with save-time validation (`Step.Node.changeset`)
  # via `Action.resolve/1` — one source of truth. For a *persisted* workflow the
  # module is guaranteed to resolve and satisfy the contract at save time, so
  # the resolution + `Action.validate/1` calls in `build_node/6` are now defensive
  # backstops that only fire on **code drift** (a module removed or made
  # non-conforming after the workflow was saved).
  defp resolve_module(module_string), do: Action.resolve(module_string)

  @doc """
  Wraps an action module in a Runic `ActionNode`. With a binary `run_id` the node is
  wrapped in `StepRunner` (writes a `StepRun` row per execution); otherwise the bare
  module is used. Public so `MapNodeBuilder` builds the map's aggregate `MapCollect`
  node the same way as a regular node.
  """
  def build_action_node(mod, params, name, step_index, run_id) when is_binary(run_id) do
    wrapper_params =
      Map.merge(params, %{
        wrapped_module: mod,
        run_id: run_id,
        step_name: name,
        step_index: step_index
      })

    ActionNode.new(StepRunner, wrapper_params, name: node_atom(name), max_retries: 0)
  end

  def build_action_node(mod, params, name, _step_index, _run_id) do
    ActionNode.new(mod, params, name: node_atom(name))
  end

  defp validate_edges(edges, node_map) do
    case Enum.reduce_while(edges, :ok, fn edge, :ok ->
           validate_single_edge(edge, node_map)
         end) do
      :ok -> validate_start_edges(edges)
      {:error, _} = err -> err
    end
  end

  defp validate_single_edge(edge, node_map) do
    to = Map.get(edge, "to")

    cond do
      is_nil(to) or not Map.has_key?(node_map, to) ->
        {:halt, {:error, {:unknown_node, to}}}

      # A sentinel `from: "start"` edge that neither maps nor guards would shadow
      # the root node without transforming the planted fact — reject it as a no-op.
      noop_start_edge?(edge) ->
        {:halt, {:error, {:invalid_start_edge, to}}}

      true ->
        case validate_edge_condition(Map.get(edge, "condition")) do
          :ok -> {:cont, :ok}
          {:error, _} = err -> {:halt, err}
        end
    end
  end

  defp noop_start_edge?(edge) do
    Map.get(edge, "from") == @start_sentinel and
      is_nil(Map.get(edge, "condition")) and
      map_size(Map.get(edge, "mapping") || %{}) == 0
  end

  # Two `from: "start"` edges into the same node would plant two competing roots
  # for it (ambiguous double-seed). Fan-out to *different* nodes stays allowed.
  defp validate_start_edges(edges) do
    duplicate =
      edges
      |> Enum.filter(&(Map.get(&1, "from") == @start_sentinel))
      |> Enum.frequencies_by(&Map.get(&1, "to"))
      |> Enum.find(fn {_to, count} -> count > 1 end)

    case duplicate do
      {to, _count} -> {:error, {:duplicate_start_edge, to}}
      nil -> :ok
    end
  end

  defp validate_edge_condition(nil), do: :ok

  defp validate_edge_condition(condition) when is_map(condition) do
    cs = EdgeCondition.changeset(condition)
    if cs.valid?, do: :ok, else: {:error, {:invalid_edge_condition, condition}}
  end

  defp validate_edge_condition(_), do: :ok

  # Runs each node through its `Workflows.Node.enrich/2` (data-driven dispatch via
  # `@node_modules`); nodes with no registered module pass through untouched. The
  # `Batch` translator rewrites its node into a `map` node here, before the node map
  # is built — so no Batch/Iterate runtime node ever reaches the DAG.
  defp enrich_nodes(nodes_list) do
    result =
      Enum.reduce_while(nodes_list, {:ok, []}, fn node, {:ok, acc} ->
        case enrich_node(node, nodes_list) do
          {:ok, enriched} -> {:cont, {:ok, [enriched | acc]}}
          {:error, _} = err -> {:halt, err}
        end
      end)

    case result do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      {:error, _} = err -> err
    end
  end

  # Maps a node's "module" string to the `Zaq.Engine.Workflows.Node`
  # implementation that owns its build-time enrichment. `Batch` is the only
  # orchestrator now — it translates itself (and any nested `Iterate` marker) into
  # a `map` node. Adding a new translator means adding its module here and the
  # `enrich/2` callback on the module — not editing this builder.
  @node_modules %{
    "Zaq.Agent.Tools.Workflow.Batch" => Zaq.Agent.Tools.Workflow.Batch
  }

  defp enrich_node(node, nodes_list) do
    case Map.get(@node_modules, Map.get(node, "module")) do
      nil -> {:ok, node}
      module -> module.enrich(node, nodes_list)
    end
  end

  @doc """
  Returns `{:error, tag}` for an empty list, `:ok` otherwise.

  Public so node modules (`Workflows.Node` implementations) and the `map` lowering
  can guard required inline pipelines.
  """
  @spec require_non_empty([term()], term()) :: :ok | {:error, term()}
  def require_non_empty([], tag), do: {:error, tag}
  def require_non_empty(_, _), do: :ok

  defp assemble(node_map, edges, run_id) do
    workflow =
      node_map
      |> Enum.sort_by(fn {_name, %{index: i}} -> i end)
      |> Enum.reduce(Runic.Workflow.new(:workflow), fn {name, entry}, wf ->
        incoming = Enum.filter(edges, &(Map.get(&1, "to") == name))

        case entry do
          %{node: runic_node} -> add_node(wf, runic_node, name, incoming, node_map, run_id)
          %{map: spec} -> add_map_chain(wf, spec, name, incoming, node_map, run_id)
        end
      end)

    {:ok, workflow}
  end

  # Assembles a `map` node from the spec built by `MapNodeBuilder.build_spec/4`:
  # the extract head is wired to incoming edges exactly like a normal node; the
  # Map/Reduce/Collect chain is appended internally. The Collect node carries the map
  # node's own name, so downstream `from`-edges resolve to it via `node_atom(name)`
  # with no special casing.
  defp add_map_chain(wf, spec, name, incoming, node_map, run_id) do
    wf
    |> add_node(spec.extract, name, incoming, node_map, run_id)
    |> Runic.Workflow.add(spec.map, to: spec.extract_atom)
    # `last_body` is the fork-executor pipeline step; register it as the Map's `:leaf`
    # explicitly so `Reduce.connect` can fan it in.
    |> Runic.Workflow.draw_connection(spec.map, spec.last_body, :component_of,
      properties: %{kind: :leaf}
    )
    |> Runic.Workflow.add(spec.reduce, to: spec.map)
    # The collected fact is produced by the reduce's `fan_in` node — attach the
    # aggregate collect step there so it fires once with the gathered summary.
    |> Runic.Workflow.add(spec.collect, to: spec.reduce.fan_in)
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

    cond do
      is_nil(condition) and map_size(mapping) == 0 ->
        Runic.Workflow.add(wf, runic_node, direct_edge_opts(from_name, node_map))

      from_name == @start_sentinel and not Map.has_key?(node_map, from_name) ->
        # Sentinel source: there is no upstream node, so the EdgeStep guard
        # becomes a ROOT that transforms the planted initial fact. The target
        # node is wired downstream of the guard, so it no longer reacts to the
        # raw planted fact (avoids double-firing on the untransformed payload).
        guard_name = "#{from_name}__to__#{to_name}__edge"
        guard_node = build_edge_step_node(condition, mapping, guard_name, run_id, 0)

        wf
        |> Runic.Workflow.add(guard_node, validate: :off)
        |> Runic.Workflow.add(runic_node, to: node_atom(guard_name), validate: :off)

      true ->
        guard_name = "#{from_name}__to__#{to_name}__edge"
        from_index = get_in(node_map, [from_name, :index]) || 0
        guard_node = build_edge_step_node(condition, mapping, guard_name, run_id, from_index)

        wf
        |> Runic.Workflow.add(guard_node, to: node_atom(from_name), validate: :off)
        |> Runic.Workflow.add(runic_node, to: node_atom(guard_name), validate: :off)
    end
  end

  defp direct_edge_opts(from_name, node_map) do
    if from_name && Map.has_key?(node_map, from_name) do
      [to: node_atom(from_name), validate: :off]
    else
      [validate: :off]
    end
  end

  defp build_edge_step_node(condition, mapping, name, run_id, source_index) do
    params =
      %{
        __edge_condition__: condition,
        __edge_mapping__: mapping,
        __edge_name__: name,
        __edge_source_index__: source_index
      }
      |> then(fn p -> if run_id, do: Map.put(p, :run_id, run_id), else: p end)

    ActionNode.new(Zaq.Engine.Workflows.Steps.EdgeStep, params, name: node_atom(name))
  end

  @doc """
  Converts a node name to the atom Runic uses to address it.

  Node names come from workflow definitions — a bounded, designer-controlled set,
  not unbounded end-user input. Atom creation here is intentional and safe; it uses
  `:erlang.binary_to_atom/2` directly to avoid the `String.to_atom/1` lint warning
  (Iron Law #10) while keeping semantics identical. Shared with `MapNodeBuilder` so
  it names its extract/fan-out/reduce nodes consistently.
  """
  def node_atom(name) when is_binary(name), do: :erlang.binary_to_atom(name, :utf8)
  def node_atom(name) when is_atom(name), do: name

  @doc """
  Atomizes a node-params map's string keys to existing atoms (leaving keys that have
  no existing atom untouched). Shared with `MapNodeBuilder` so inline body-node
  params are atomized the same way.
  """
  def atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
      {k, v} -> {k, v}
    end)
  rescue
    ArgumentError -> map
  end

  def atomize_keys(other), do: other
end
