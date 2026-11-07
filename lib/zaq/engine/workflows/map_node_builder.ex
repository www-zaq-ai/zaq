defmodule Zaq.Engine.Workflows.MapNodeBuilder do
  @moduledoc """
  Builds a `"map"` node's executable Runic chain — the general iteration primitive
  behind `Batch`.

  A `"map"` node fans an inline `body` pipeline over the `over` collection of the
  incoming fact and collects the results:

      MapExtract(over) -> %Map{FanOut -> fork executor} -> %Reduce{collect} -> MapCollect

  Batch runs each fork's whole body and post-process together, in scheduler
  order. Iterate uses an ordered step that finishes each item's whole pipeline
  before starting the next item in input order. Both execute through StepRunner
  for per-item persistence and collect through MapCollect under the parent name.

  `build_spec/4` returns a plain spec map; `DagBuilder.add_map_chain/5` wires the
  extract head to incoming edges and appends the Map/Reduce/Collect chain — the same
  way `DagBuilder` assembles a regular node. The shared node-building primitives
  (`node_atom/1`, `atomize_keys/1`, `build_action_node/5`) live in `DagBuilder` and
  are reused here.

  Body and post-process nodes may declare an incoming `mapping`, using the same
  field references as workflow edges. Pipelines using mappings inherit the parent
  cascade and add outputs under local body names, so `capture.result` resolves within that
  item only. Collection restores the parent cascade, including when every item
  fails or the collection is empty. Persisted StepRun names remain `<map>/<step>[i]`.
  """

  alias Runic.Workflow.Step
  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.Action
  alias Zaq.Engine.Workflows.DagBuilder
  alias Zaq.Engine.Workflows.Step.Edge
  alias Zaq.Engine.Workflows.StepRunner
  alias Zaq.Engine.Workflows.Steps
  alias Zaq.Engine.Workflows.WorkflowRun

  # Backstop: the global `max_items` cap for a `map` fan-out when a node declares no
  # `params["max_items"]`. Overridable via
  # `config :zaq, Zaq.Engine.Workflows, map_max_items: N`.
  @default_map_max_items 10_000

  @doc """
  Lowers a `"map"` node's params into the spec map consumed by `DagBuilder`'s
  assembly: `%{ordered, collect}` for Iterate, or
  `%{extract, extract_atom, map, last_body, reduce, collect}` for Batch.

  Returns `{:error, {:map_body_required, name}}` (or a body-node resolution error)
  when the inline `body` pipeline is empty/unresolvable.
  """
  @spec build_spec(String.t(), map(), non_neg_integer(), String.t() | nil) ::
          {:ok, map()} | {:error, term()}
  def build_spec(name, params, index, run_id) do
    body = Map.get(params, "body") || []
    post = Map.get(params, "post_process") || []
    strategy = Map.get(params, "strategy", "skip_and_continue")

    with :ok <- DagBuilder.require_non_empty(body, {:map_body_required, name}),
         {:ok, body_specs} <- build_fork_specs(body, name, strategy, run_id),
         {:ok, post_specs} <- build_fork_specs(post, name, strategy, run_id) do
      spec = build_execution_spec(name, params, index, run_id, body_specs ++ post_specs)

      collect =
        DagBuilder.build_action_node(
          Steps.MapCollect,
          %{__map_prefix__: "#{name}/"},
          name,
          index,
          run_id
        )

      {:ok, Map.put(spec, :collect, collect)}
    end
  end

  defp build_execution_spec(name, %{"ordered" => true} = params, index, run_id, specs) do
    opts = Map.put(delivery_opts(params), :inherit_cascade, true)

    ordered =
      Step.new(%{
        name: DagBuilder.node_atom("#{name}__iterate"),
        work: fn input ->
          input
          |> extract_items(name, index, params["over"], opts, run_id)
          |> Enum.reduce(%{input: [], __cascade__: %{}}, fn fact, acc ->
            result = run_ordered_fork(fact, specs)
            reduce_item(result, acc)
          end)
        end
      })

    %{ordered: ordered}
  end

  defp build_execution_spec(name, params, index, run_id, specs) do
    # Batch forks execute atomically, but Runic chooses their order.
    mapped? = Enum.any?(specs, &(map_size(&1.mapping) > 0))
    extract_atom = DagBuilder.node_atom("#{name}__map_extract")
    fan_out_hash = :erlang.phash2({:map_fan_out, name})
    map_component = DagBuilder.node_atom("#{name}__map")
    fork_step = build_fork_executor(name, specs)

    pipeline =
      map_component
      |> Runic.Workflow.new()
      |> Runic.Workflow.add_step(%Runic.Workflow.FanOut{
        hash: fan_out_hash,
        name: map_component
      })
      |> Runic.Workflow.add(fork_step, to: fan_out_hash)

    map_struct = %Runic.Workflow.Map{
      name: map_component,
      hash: :erlang.phash2({:map, name}),
      pipeline: pipeline
    }

    %{
      extract:
        build_extract_node(
          extract_atom,
          name,
          index,
          Map.get(params, "over"),
          Map.put(delivery_opts(params), :inherit_cascade, mapped?),
          run_id
        ),
      extract_atom: extract_atom,
      map: map_struct,
      last_body: fork_step,
      reduce: build_map_reduce(name, map_component, mapped?)
    }
  end

  defp build_fork_specs(nodes, map_name, strategy, run_id) do
    result =
      Enum.reduce_while(nodes, {:ok, []}, fn bnode, {:ok, acc} ->
        case build_fork_spec(bnode, map_name, strategy, run_id) do
          {:ok, spec} -> {:cont, {:ok, [spec | acc]}}
          {:error, _} = err -> {:halt, err}
        end
      end)

    case result do
      {:ok, rev} -> {:ok, Enum.reverse(rev)}
      {:error, _} = err -> err
    end
  end

  # Keep incoming mappings outside Action params. StepRunner still owns execution,
  # persistence, retries and isolation for each mapped fork step.
  defp build_fork_spec(bnode, map_name, strategy, run_id) do
    type = Map.get(bnode, "type")
    bname = Map.get(bnode, "name")
    bparams = Map.get(bnode, "params") || %{}
    mapping = Map.get(bnode, "mapping") || %{}

    if type in ["action", "agent"] do
      with {:ok, mod} <- Action.resolve(Map.get(bnode, "module")),
           :ok <- Action.validate(mod),
           :ok <- validate_body_mapping(map_name, bname, mapping) do
        base = bparams |> DagBuilder.atomize_keys() |> Map.put(:__map_strategy__, strategy)

        params =
          Map.merge(base, %{
            wrapped_module: mod,
            run_id: run_id,
            step_name: "#{map_name}/#{bname}",
            step_index: 0
          })

        {:ok, %{params: params, name: bname, mapping: mapping}}
      end
    else
      {:error, {:unsupported_map_body_node_type, type}}
    end
  end

  defp validate_body_mapping(map_name, name, mapping) do
    edge = Edge.changeset(%Edge{}, %{from: map_name, to: name, mapping: mapping})
    if edge.valid?, do: :ok, else: {:error, {:invalid_body_mapping, name}}
  end

  # One Runic step that runs a fork's whole body + post_process chain in order. Runic
  # invokes it once per fan-out unit; it returns the fork's final fact (or the
  # `__map_error__` sentinel for a failed fork) — exactly what the `FanIn` reducer
  # consumes.
  defp build_fork_executor(name, specs) do
    Step.new(%{
      name: DagBuilder.node_atom("#{name}__map_fork"),
      work: fn fact -> run_fork(fact, specs) end
    })
  end

  # Threads the fork fact through each sub-step via `StepRunner`. An isolated fork
  # failure surfaces from `StepRunner` as `{:ok, sentinel}` and flows on (later
  # sub-steps short-circuit on it); a non-isolated failure (`:fail_workflow`) returns
  # `{:error, _}` — its `StepRun` row is already `"failed"`, so we emit the sentinel
  # to keep the FanIn cardinality intact and let `finalize/2` fail the run.
  defp run_fork(%{__map_empty__: true} = fact, _specs) do
    %{__map_empty__: true, __map_parent_cascade__: fact.__cascade__}
  end

  defp run_fork(fact, specs) do
    mapped? = Enum.any?(specs, &(map_size(&1.mapping) > 0))

    fact
    |> run_pipeline(specs, mapped?)
    |> case do
      {:ok, result} -> result
      {:error, _reason, index} -> %{"__map_index__" => index, "__map_error__" => true}
    end
    |> put_parent_cascade(fact, mapped?)
  end

  defp run_ordered_fork(%{__map_empty__: true} = fact, specs), do: run_fork(fact, specs)

  defp run_ordered_fork(fact, specs) do
    case run_pipeline(fact, specs, true) do
      {:ok, result} ->
        put_parent_cascade(result, fact, true)

      {:error, reason, _index} ->
        # StepRunner has persisted the failure or wait. Abort this Runic step so
        # later items and downstream nodes cannot run until it is resolved.
        raise "iteration stopped: #{inspect(reason)}"
    end
  end

  defp run_pipeline(fact, specs, mapped?) do
    specs
    |> Enum.reduce_while({:ok, fact}, fn spec, {:ok, prev} ->
      params = prev |> Steps.EdgeStep.apply_mapping(spec.mapping) |> Map.merge(spec.params)

      case StepRunner.run(params, %{}) do
        {:ok, result} ->
          {:cont, {:ok, put_local_result(result, spec.name, mapped?)}}

        {:error, reason} ->
          {:halt, {:error, reason, map_index_of(prev)}}
      end
    end)
  end

  defp put_parent_cascade(result, _fact, false), do: result

  defp put_parent_cascade(result, fact, true) do
    Map.put(result, :__map_parent_cascade__, Map.get(fact, :__cascade__, %{}))
  end

  defp put_local_result(result, _name, false), do: result

  defp put_local_result(result, name, true) do
    cascade = Map.get(result, :__cascade__, Map.get(result, "__cascade__", %{}))
    cascade = Map.delete(cascade, safe_existing_atom(name))
    output = Map.drop(result, [:__cascade__, "__cascade__", :__map_index__, "__map_index__"])
    result |> Map.delete("__cascade__") |> Map.put(:__cascade__, Map.put(cascade, name, output))
  end

  defp map_index_of(fact) when is_map(fact),
    do: Map.get(fact, "__map_index__") || Map.get(fact, :__map_index__)

  defp map_index_of(_), do: nil

  defp build_map_reduce(name, map_component, mapped?) do
    reduce_name = DagBuilder.node_atom("#{name}__map_reduce")

    %Runic.Workflow.Reduce{
      name: reduce_name,
      hash: :erlang.phash2({:map_reduce, name}),
      fan_in: %Runic.Workflow.FanIn{
        map: map_component,
        init: fn -> if mapped?, do: %{input: [], __cascade__: %{}}, else: [] end,
        reducer: &reduce_item/2,
        hash: :erlang.phash2({:map_fan_in, name}),
        name: reduce_name
      }
    }
  end

  # Carry only the parent cascade across fan-in, including all-error and empty
  # batches. Item-local names stay inside their fork and cannot overwrite it.
  defp reduce_item(item, %{input: results} = acc) do
    acc
    |> Map.put(:__cascade__, Map.fetch!(item, :__map_parent_cascade__))
    |> Map.put(:input, reduce_item(item, results))
  end

  defp reduce_item(%{__map_empty__: true}, results), do: results

  defp reduce_item(item, results) do
    if map_error_item?(item), do: results, else: results ++ [summarize_map_item(item)]
  end

  defp map_error_item?(item) when is_map(item),
    do: Map.get(item, "__map_error__") == true or Map.get(item, :__map_error__) == true

  defp map_error_item?(_item), do: false

  defp summarize_map_item(item) when is_map(item) do
    idx = Map.get(item, "__map_index__") || Map.get(item, :__map_index__)

    clean =
      Map.drop(item, [
        "__map_index__",
        :__map_index__,
        :__cascade__,
        "__cascade__",
        :__map_parent_cascade__
      ])

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
    |> Enum.map(fn {unit, i} ->
      fact = stamp_unit(unit, i, opts)

      case opts.inherit_cascade && Map.get(input, :__cascade__, Map.get(input, "__cascade__")) do
        false -> fact
        nil -> fact
        cascade -> Map.put(fact, :__cascade__, cascade)
      end
    end)
    |> retain_empty_cascade(input, opts)
  end

  defp extract_items(_input, _name, _index, _over, _opts, _run_id), do: []

  defp retain_empty_cascade([], input, %{inherit_cascade: true}) do
    [
      %{
        __map_empty__: true,
        __cascade__: Map.get(input, :__cascade__, Map.get(input, "__cascade__", %{}))
      }
    ]
  end

  defp retain_empty_cascade(facts, _input, _opts), do: facts

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
end
