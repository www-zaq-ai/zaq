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
            "params" => %{"agent_name" => "MailResponder", "input" => "Draft a reply"},
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
  `map` lowering (see "map node lowering" below). `Iterate` no longer exists as a
  runtime module — it survives only as an inline `process` marker that
  `Batch.enrich/2` unwraps into the map body.

  A Batch node declares its sub-pipeline as **inline node maps** inside `params`:

      %{
        "name" => "batch_contacts",
        "type" => "action",
        "module" => "Zaq.Agent.Tools.Workflow.Batch",
        "params" => %{
          "batch_size" => 4,
          "strategy"   => "skip_and_continue",
          "process" => [
            %{"name" => "iterate_contacts", "type" => "action",
              "module" => "Zaq.Agent.Tools.Workflow.Iterate",
              "params" => %{"pipeline" => [ ...inline body nodes... ]}}
          ],
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
  alias Runic.Workflow.Step
  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.Action
  alias Zaq.Engine.Workflows.EdgeCondition
  alias Zaq.Engine.Workflows.StepRunner
  alias Zaq.Engine.Workflows.Steps
  alias Zaq.Engine.Workflows.WorkflowRun

  @type steps :: map()
  @type build_result :: {:ok, Runic.Workflow.t()} | {:error, term()}

  # Backstop: the global `max_items` cap for a `map` fan-out when a node
  # declares no `params["max_items"]`. Overridable via
  # `config :zaq, Zaq.Engine.Workflows, map_max_items: N`.
  @default_map_max_items 10_000

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
    with {:ok, spec} <- build_map_spec(name, params, index, run_id) do
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

  defp build_action_node(mod, params, name, step_index, run_id) when is_binary(run_id) do
    wrapper_params =
      Map.merge(params, %{
        wrapped_module: mod,
        run_id: run_id,
        step_name: name,
        step_index: step_index
      })

    ActionNode.new(StepRunner, wrapper_params, name: node_atom(name), max_retries: 0)
  end

  defp build_action_node(mod, params, name, _step_index, _run_id) do
    ActionNode.new(mod, params, name: node_atom(name))
  end

  # --- map node lowering (general iteration primitive) ---
  #
  # A `"map"` node fans an inline `body` pipeline over the `over` collection of the
  # incoming fact and collects the results. It is lowered into a self-contained
  # Runic chain (no Batch coupling):
  #
  #   MapExtract(over) -> %Map{FanOut -> body steps} -> %Reduce{collect} -> MapCollect
  #
  # `MapExtract`/`MapCollect` live in `Steps.*`. Body steps are `StepRunner`-wrapped
  # and named `"<map>/<step>"`; their per-fork StepRun becomes `"<map>/<step>[i]"`
  # via `__map_index__`. `MapCollect` is wrapped under the map node's own name, so it
  # writes the single aggregate StepRun and is the chain's tail for outgoing edges.
  defp build_map_spec(name, params, index, run_id) do
    over = Map.get(params, "over")
    body = Map.get(params, "body") || []
    post = Map.get(params, "post_process") || []
    strategy = Map.get(params, "strategy", "skip_and_continue")

    with :ok <- require_non_empty(body, {:map_body_required, name}),
         {:ok, body_steps} <- build_map_body(body, name, strategy, run_id),
         {:ok, post_steps} <- build_map_body(post, name, strategy, run_id) do
      # `post_process` runs as a per-fork tail: its steps are appended to the body
      # pipeline so they execute inside each fork after the body (Batch parity).
      steps = body_steps ++ post_steps
      extract_atom = node_atom("#{name}__map_extract")
      fan_out_hash = :erlang.phash2({:map_fan_out, name})
      map_component = node_atom("#{name}__map")

      pipeline = build_map_pipeline(map_component, fan_out_hash, steps)

      map_struct = %Runic.Workflow.Map{
        name: map_component,
        hash: :erlang.phash2({:map, name}),
        pipeline: pipeline
      }

      {:ok,
       %{
         extract:
           build_extract_node(extract_atom, name, index, over, delivery_opts(params), run_id),
         extract_atom: extract_atom,
         map: map_struct,
         last_body: List.last(steps),
         reduce: build_map_reduce(name, map_component),
         collect:
           build_action_node(Steps.MapCollect, %{__map_prefix__: "#{name}/"}, name, index, run_id)
       }}
    end
  end

  defp build_map_body(body, map_name, strategy, run_id) do
    result =
      Enum.reduce_while(body, {:ok, []}, fn bnode, {:ok, acc} ->
        case build_map_body_node(bnode, map_name, strategy, run_id) do
          {:ok, step} -> {:cont, {:ok, [step | acc]}}
          {:error, _} = err -> {:halt, err}
        end
      end)

    case result do
      {:ok, rev} -> {:ok, Enum.reverse(rev)}
      {:error, _} = err -> err
    end
  end

  defp build_map_body_node(bnode, map_name, strategy, run_id) do
    type = Map.get(bnode, "type")
    bname = Map.get(bnode, "name")
    bparams = Map.get(bnode, "params") || %{}

    if type in ["action", "agent"] do
      with {:ok, mod} <- resolve_module(Map.get(bnode, "module")),
           :ok <- Action.validate(mod) do
        base = bparams |> atomize_keys() |> Map.put(:__map_strategy__, strategy)
        {:ok, build_action_node(mod, base, "#{map_name}/#{bname}", 0, run_id)}
      end
    else
      {:error, {:unsupported_map_body_node_type, type}}
    end
  end

  defp build_map_pipeline(map_component, fan_out_hash, [first | rest]) do
    pipeline =
      map_component
      |> Runic.Workflow.new()
      |> Runic.Workflow.add_step(%Runic.Workflow.FanOut{hash: fan_out_hash, name: map_component})
      |> Runic.Workflow.add(first, to: fan_out_hash)

    {pipeline, _last} =
      Enum.reduce(rest, {pipeline, first}, fn step, {wf, prev} ->
        {Runic.Workflow.add(wf, step, to: prev), step}
      end)

    pipeline
  end

  defp build_map_reduce(name, map_component) do
    reduce_name = node_atom("#{name}__map_reduce")

    %Runic.Workflow.Reduce{
      name: reduce_name,
      hash: :erlang.phash2({:map_reduce, name}),
      fan_in: %Runic.Workflow.FanIn{
        map: map_component,
        init: fn -> [] end,
        reducer: fn item, acc ->
          # A non-fatal failed fork emits an `__map_error__` sentinel purely to keep the
          # FanIn cardinality intact (so it fires); it is excluded from the results list.
          # The failure itself is recovered from the fork's `StepRun` row by `MapCollect`.
          if map_error_item?(item), do: acc, else: acc ++ [summarize_map_item(item)]
        end,
        hash: :erlang.phash2({:map_fan_in, name}),
        name: reduce_name
      }
    }
  end

  defp map_error_item?(item) when is_map(item),
    do: Map.get(item, "__map_error__") == true or Map.get(item, :__map_error__) == true

  defp map_error_item?(_item), do: false

  defp summarize_map_item(item) when is_map(item) do
    idx = Map.get(item, "__map_index__") || Map.get(item, :__map_index__)
    clean = Map.drop(item, ["__map_index__", :__map_index__, :__cascade__, "__cascade__"])
    %{"index" => idx, "status" => "completed", "result" => clean}
  end

  defp summarize_map_item(item), do: %{"index" => nil, "status" => "completed", "result" => item}

  # Delivery/throughput knobs read off the map node's params (the Batch superset).
  # `delivery`/`field` nil ⇒ the legacy per-item merge shape (item map merged into
  # body params). With `delivery`, each unit is wrapped under `field`:
  #   - "list" ⇒ fan out over chunks of `chunk_size` (nil ⇒ 1); body gets %{field => chunk}
  #   - "item" ⇒ fan out over individual items; body gets %{field => item}
  defp delivery_opts(params) do
    %{
      delivery: Map.get(params, "delivery"),
      field: Map.get(params, "field"),
      chunk_size: Map.get(params, "chunk_size"),
      max_items: Map.get(params, "max_items") || map_max_items()
    }
  end

  # Effective `map` fan-out cap: per-node `max_items` wins (resolved into the opts
  # above); this is the global backstop when a node declares none.
  defp map_max_items do
    :zaq
    |> Application.get_env(Zaq.Engine.Workflows, [])
    |> Keyword.get(:map_max_items, @default_map_max_items)
  end

  # The extract node must emit a plain *list* so the Runic `FanOut` can split it.
  # A Jido `ActionNode` can't (Jido validates action output as a map), so this is a
  # plain Runic `Step` whose work reads the `over` collection out of the upstream
  # fact, groups/wraps per the delivery opts, and stamps each unit with
  # `__map_index__` for per-fork identity.
  defp build_extract_node(extract_atom, name, index, over, opts, run_id) do
    Step.new(%{
      name: extract_atom,
      work: fn input -> extract_items(input, name, index, over, opts, run_id) end
    })
  end

  defp extract_items(input, name, index, over, opts, run_id) when is_map(input) do
    items = input |> fetch_over(over) |> List.wrap()
    enforce_max_items!(name, index, length(items), opts, run_id)

    items
    |> group_units(opts)
    |> Enum.with_index()
    |> Enum.map(fn {unit, i} -> stamp_unit(unit, i, opts) end)
  end

  defp extract_items(_input, _name, _index, _over, _opts, _run_id), do: []

  # Run-time guard: a runtime collection larger than the effective cap must
  # not fan out unbounded. Runic swallows step exceptions and only logs them, so a
  # bare raise would silently complete the run; instead we record a failed aggregate
  # StepRun for the map node (so `finalize/2` fails the run and BO renders the
  # failure) and then raise to abort this fork + skip the downstream fan-out.
  # The agent reads the violation back from the row via `Workflows.map_over_limit/1`.
  defp enforce_max_items!(name, index, count, %{max_items: cap}, run_id)
       when is_integer(cap) and count > cap do
    message =
      "map node #{inspect(name)} would fan out over #{count} items, " <>
        "exceeding the max_items cap of #{cap}"

    record_over_limit(run_id, name, index, count, cap, message)
    raise message
  end

  defp enforce_max_items!(_name, _index, _count, _opts, _run_id), do: :ok

  defp record_over_limit(nil, _name, _index, _count, _cap, _message), do: :ok

  defp record_over_limit(run_id, name, index, count, cap, message) do
    {:ok, step_run} =
      Workflows.create_step_run(%WorkflowRun{id: run_id}, %{
        step_name: name,
        step_index: index,
        status: "running"
      })

    Workflows.fail_step_run(
      step_run,
      %{"reason" => message, "code" => "map_over_limit", "count" => count, "cap" => cap},
      []
    )

    Workflows.tick_log_summary(run_id)
    :ok
  end

  # "list" delivery fans out over chunks; everything else fans out over items.
  defp group_units(items, %{delivery: "list", chunk_size: size}),
    do: Enum.chunk_every(items, size || 1)

  defp group_units(items, _opts), do: items

  defp fetch_over(input, over) when is_binary(over) do
    Map.get(input, over) || Map.get(input, safe_existing_atom(over))
  end

  defp fetch_over(_input, _over), do: nil

  # With a delivery `field`, wrap the unit under it (atom key, to satisfy the body
  # action's schema). Without one, fall back to the legacy merge shape.
  defp stamp_unit(unit, i, %{delivery: d, field: field})
       when d in ["item", "list"] and field != nil do
    %{safe_existing_atom(field) => unit, "__map_index__" => i}
  end

  defp stamp_unit(unit, i, _opts), do: stamp_item(unit, i)

  defp stamp_item(item, i) when is_map(item), do: Map.put(item, "__map_index__", i)
  defp stamp_item(item, i), do: %{"__map_item__" => item, "__map_index__" => i}

  defp safe_existing_atom(str) do
    String.to_existing_atom(str)
  rescue
    ArgumentError -> nil
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

  # Adds a lowered `map` node: the extract head is wired to incoming edges exactly
  # like a normal node; the Map/Reduce/Collect chain is appended internally. The
  # Collect node carries the map node's own name, so downstream `from`-edges resolve
  # to it via `node_atom(name)` with no special casing.
  defp add_map_chain(wf, spec, name, incoming, node_map, run_id) do
    wf
    |> add_node(spec.extract, name, incoming, node_map, run_id)
    |> Runic.Workflow.add(spec.map, to: spec.extract_atom)
    # Runic's Map.connect only marks a `:leaf` for `%Runic.Workflow.Step{}` pipeline
    # nodes; our body steps are `ActionNode`s, so register the leaf explicitly so
    # `Reduce.connect` can fan them in.
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

    if not is_nil(condition) or map_size(mapping) > 0 do
      guard_name = "#{from_name}__to__#{to_name}__edge"
      from_index = get_in(node_map, [from_name, :index]) || 0
      guard_node = build_edge_step_node(condition, mapping, guard_name, run_id, from_index)

      wf
      |> Runic.Workflow.add(guard_node, to: node_atom(from_name), validate: :off)
      |> Runic.Workflow.add(runic_node, to: node_atom(guard_name), validate: :off)
    else
      Runic.Workflow.add(wf, runic_node, direct_edge_opts(from_name, node_map))
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

  # Node names come from workflow definitions — a bounded, designer-controlled
  # set, not unbounded end-user input. Atom creation here is intentional and
  # safe. Using :erlang.binary_to_atom/2 directly to avoid the String.to_atom/1
  # lint warning (Iron Law #10) while keeping semantics identical.
  defp node_atom(name) when is_binary(name), do: :erlang.binary_to_atom(name, :utf8)
  defp node_atom(name) when is_atom(name), do: name

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
