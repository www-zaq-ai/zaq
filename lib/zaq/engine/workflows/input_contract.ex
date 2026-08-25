defmodule Zaq.Engine.Workflows.InputContract do
  @moduledoc """
  Derives what a workflow's trigger payload must contain, from the graph alone.

  A workflow is a DAG of nodes wired by edges. Every node needs input fields;
  some are written by an upstream step, and the rest must arrive in the trigger
  payload. This module walks the graph — edge mappings, `{{...}}` references in
  node params, edge conditions, and each action module's `schema/0` and
  `output_schema/0` — and sorts one from the other.

  `contract/2` is the entry point and returns the whole picture in one traversal:

      %{
        valid: false,
        required_inputs: ["email topic", "input.name"],
        required_input_shape: %{"email topic" => nil, "input" => %{"name" => nil}},
        missing_inputs: ["email topic"],
        invalid_inputs: [%{path: "input.name", expected: "string", got: "integer"}],
        unsatisfiable_inputs: []
      }

  The other public functions expose the same data one piece at a time, each
  re-walking the graph: `all_inputs/1`, `fed_by_steps/1`, `missing/1`,
  `required_inputs/1`, `required_input_shape/1`, `unsatisfiable_inputs/1`, and
  `check/2` to test a candidate payload.

  ## Vocabulary

    * **Need** — "`node.field` is written from `source`". Everything here is
      derived from the list of needs; qualifying by node keeps two nodes needing
      a `subject` distinct.
    * **`start`** — the namespace of the trigger payload. It is not a node, so a
      field sourced from `start.*` is never step-fed: `missing = all_inputs −
      fed_by_steps` leaves it required without special-casing.
    * **Required input** — a dotted path into the payload (`"input.name"` means
      an `"input"` object holding a `"name"`), the way `FactLookup` reads it at
      run time.
    * **Unsatisfiable input** — a field whose source names no producer in the
      graph. An authoring error rather than a payload gap, so it is reported
      separately instead of being asked of the caller.
    * **Expectation** — the kind of value a required path's field declares, read
      from the action's own schema. Known only where the payload value reaches that
      field whole; see `expectations/1`.
  """

  alias Zaq.Engine.Workflows.Action
  alias Zaq.Engine.Workflows.FactLookup
  alias Zaq.Engine.Workflows.Placeholders
  alias Zaq.Engine.Workflows.Workflow

  @start "start"

  @doc """
  Every input field every node needs, as `"node.field"`.

  A node needs a field when an incoming edge mapping writes it, when a reference
  inside its own params reads it, or when its action schema requires it and
  nothing else supplies it. An edge condition needs the field it gates on, keyed
  by the edge (`"from->to.field"`) since it writes into neither endpoint.
  """
  @spec all_inputs(Workflow.t() | map()) :: MapSet.t(String.t())
  def all_inputs(workflow), do: workflow |> needs() |> all_inputs_from()

  defp all_inputs_from(needs), do: MapSet.new(needs, &qualify/1)

  @doc """
  The inputs fed by the output of a previous step, as `"node.field"`.

  A field is fed when **every** source that writes into it names another node.
  A `start.*` source is the trigger payload, not a step output, so a field with
  even one `start` source is not fed.
  """
  @spec fed_by_steps(Workflow.t() | map()) :: MapSet.t(String.t())
  def fed_by_steps(workflow), do: workflow |> needs() |> fed_by_steps_from()

  defp fed_by_steps_from(needs) do
    needs
    |> Enum.group_by(&qualify/1)
    |> Enum.filter(fn {_field, needs} -> Enum.all?(needs, &(&1.kind == :step)) end)
    |> MapSet.new(fn {field, _needs} -> field end)
  end

  @doc "`all_inputs/1` minus `fed_by_steps/1` — the inputs no previous step feeds."
  @spec missing(Workflow.t() | map()) :: MapSet.t(String.t())
  def missing(workflow), do: workflow |> needs() |> missing_from()

  defp missing_from(needs),
    do: MapSet.difference(all_inputs_from(needs), fed_by_steps_from(needs))

  @doc """
  The paths the trigger payload must carry, as dotted strings.

  This is `missing/1` translated from `"node.field"` into what a caller can
  actually send: the `start.*` sources behind each unfed field, with the `start.`
  prefix stripped and duplicates collapsed.
  """
  @spec required_inputs(Workflow.t() | map()) :: [String.t()]
  def required_inputs(workflow), do: workflow |> needs() |> required_inputs_from()

  defp required_inputs_from(needs) do
    unfed = missing_from(needs)

    needs
    |> Enum.filter(&(&1.kind == :start and qualify(&1) in unfed))
    |> Enum.map(&String.replace_prefix(&1.source, @start <> ".", ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  The required paths that carry a declared type, as `%{path => [spec]}`.

  A path is typed only where its value reaches a schema-required field whole — a
  mapping target, a schema-required field of an entry node, or a param the author
  wrote as a lone `{{...}}`. An interpolated reference resolves to a string whatever
  the payload holds, and a condition field has no schema, so neither is typed.

  A path several nodes read collects one spec per node: the value has to satisfy all
  of them, since every one of those nodes runs.
  """
  @spec expectations(Workflow.t() | map()) :: %{String.t() => [term()]}
  def expectations(workflow), do: workflow |> needs() |> expectations_from()

  defp expectations_from(needs) do
    unfed = missing_from(needs)

    needs
    |> Enum.filter(&(&1.kind == :start and &1.expects != nil and qualify(&1) in unfed))
    |> Enum.group_by(&String.replace_prefix(&1.source, @start <> ".", ""), & &1.expects)
    |> Map.new(fn {path, specs} -> {path, Enum.uniq(specs)} end)
  end

  @doc """
  `required_inputs/1` as the payload itself — a nested skeleton with `nil` leaves.

  A dotted path is a *shape*, not a key: `"input.name"` means the payload carries
  an `"input"` object holding `"name"`. Callers fill values into the skeleton
  instead of applying that convention themselves.

      %{"email topic" => nil, "input" => %{"name" => nil}}

  Where a path is both a leaf and a prefix of another (`"input"` and
  `"input.name"`), the nested form wins — it satisfies both.

  The skeleton is not a payload: every leaf is `nil`, and `check/2` counts a `nil`
  leaf as missing, so returning it unfilled is invalid on every path it names.
  """
  @spec required_input_shape(Workflow.t() | map()) :: map()
  def required_input_shape(workflow), do: workflow |> required_inputs() |> shape()

  defp shape(required),
    do: Enum.reduce(required, %{}, &put_path(&2, String.split(&1, ".")))

  # Inserts one dotted path into the shape map. A branch replaces a leaf at the
  # same key; a leaf never overwrites a branch.
  defp put_path(shape, [leaf]), do: Map.put_new(shape, leaf, nil)

  defp put_path(shape, [segment | rest]) do
    nested = if is_map(shape[segment]), do: shape[segment], else: %{}
    Map.put(shape, segment, put_path(nested, rest))
  end

  @doc """
  Inputs no step can feed and no payload can supply, as `%{node:, field:, source:}`.

  A field is unsatisfiable when nothing local writes it, no predecessor's output
  schema declares it, and it is not rooted in `start` — the graph names a source
  that has no producer. `source` is that dangling reference, or `nil` when the
  field is schema-required and the graph names nothing at all.

  Fixing one means editing the workflow. No payload can supply it, so it is kept
  out of `missing/1`.
  """
  @spec unsatisfiable_inputs(Workflow.t() | map()) :: [
          %{node: String.t(), field: String.t(), source: String.t() | nil}
        ]
  def unsatisfiable_inputs(workflow), do: workflow |> needs() |> unsatisfiable_from()

  defp unsatisfiable_from(needs) do
    needs
    |> Enum.filter(&(&1.kind == :unsatisfiable))
    |> Enum.map(&Map.take(&1, [:node, :field, :source]))
    |> Enum.uniq()
    |> Enum.sort_by(&{&1.node, &1.field, &1.source || ""})
  end

  @doc """
  Checks a candidate trigger payload against `required_inputs/1`.

  Takes a workflow or an already-computed `required_inputs/1` list, and returns
  `%{valid:, supplied:, missing_inputs:}`.

  Resolution goes through `FactLookup` with the payload planted under `start`, so
  a path matches the way it will at run time: nested paths descend, and the
  canonicalising fallback accepts `"Email_Topic"` for `"email topic"`.

  A path is supplied when it resolves to a value of the kind its field declares.
  Three verdicts, because they have three remediations:

    * **missing** — the path does not resolve, or resolves to `nil`. `nil` is not a
      value: the run would read it and fail exactly the way this contract exists to
      catch, the same rule `pinned_params/1` applies to an author's params. `false`,
      `0` and `""` are values a caller can mean, and supply.
    * **invalid** — the path resolves, but to a kind the field refuses. Reported as
      `%{path:, expected:, got:}` so a caller knows to send a different *kind* of
      value rather than merely a value.
    * **supplied** — everything else.

  Only a workflow carries the modules that declare types, so only the workflow arity
  type-checks. Given a bare `required_inputs/1` list there is nothing to read a type
  from, and the check is presence-only.
  """
  @spec check(Workflow.t() | map() | [String.t()], term()) :: %{
          valid: boolean(),
          supplied: [String.t()],
          missing_inputs: [String.t()],
          invalid_inputs: [%{path: String.t(), expected: String.t(), got: String.t()}]
        }
  def check(required, payload) when is_list(required),
    do: check_against(required, %{}, payload)

  def check(workflow, payload) do
    needs = needs(workflow)

    check_against(required_inputs_from(needs), expectations_from(needs), payload)
  end

  defp check_against(required, expectations, payload) do
    fact = %{__cascade__: %{start: payload}}

    {resolved, missing} =
      required
      |> Enum.map(&{&1, FactLookup.fetch(fact, qualified_start(&1))})
      |> Enum.split_with(&match?({_path, {:ok, value}} when not is_nil(value), &1))

    {supplied, invalid} =
      resolved
      |> Enum.map(fn {path, {:ok, value}} -> {path, value} end)
      |> Enum.split_with(fn {path, value} ->
        Enum.all?(Map.get(expectations, path, []), &spec_accepts?(&1, value))
      end)

    invalid = Enum.map(invalid, &violation(&1, expectations))

    %{
      valid: missing == [] and invalid == [],
      supplied: supplied |> Enum.map(&elem(&1, 0)) |> Enum.sort(),
      missing_inputs: missing |> Enum.map(&elem(&1, 0)) |> Enum.sort(),
      invalid_inputs: Enum.sort_by(invalid, & &1.path)
    }
  end

  # Names the first spec the value fails, of the one or more the path collects.
  defp violation({path, value}, expectations) do
    refused =
      expectations
      |> Map.get(path, [])
      |> Enum.find(&(not spec_accepts?(&1, value)))

    %{path: path, expected: Action.schema_kind(refused), got: Action.value_kind(value)}
  end

  @doc """
  The whole contract for one workflow in a single pass — verdict, requirements,
  and authoring errors.

  Same data as `check/2`, `required_inputs/1`, `required_input_shape/1` and
  `unsatisfiable_inputs/1` combined, but walking the graph and resolving the
  action schemas once instead of once per field.
  """
  @spec contract(Workflow.t() | map(), term()) :: %{
          valid: boolean(),
          missing_inputs: [String.t()],
          invalid_inputs: [%{path: String.t(), expected: String.t(), got: String.t()}],
          required_inputs: [String.t()],
          required_input_shape: map(),
          unsatisfiable_inputs: [
            %{node: String.t(), field: String.t(), source: String.t() | nil}
          ]
        }
  def contract(workflow, payload) do
    needs = needs(workflow)
    required = required_inputs_from(needs)
    verdict = check_against(required, expectations_from(needs), payload)

    %{
      valid: verdict.valid,
      missing_inputs: verdict.missing_inputs,
      invalid_inputs: verdict.invalid_inputs,
      required_inputs: required,
      required_input_shape: shape(required),
      unsatisfiable_inputs: unsatisfiable_from(needs)
    }
  end

  # -- iteration bodies ---------------------------------------------------------

  # An iteration node (`Batch`, or the `map` it lowers to) declares its sub-pipeline
  # inline, as params rather than as nodes. `Batch` itself has no `schema/0` and no
  # `output_schema/0`, so read as authored it needs nothing and promises nothing —
  # everything the iteration actually requires is declared by the body modules.
  #
  # So the body is lifted into the graph before anything is derived: one node per
  # sub-step, named `"<node>/<sub>"` exactly as `MapNodeBuilder` names its StepRuns,
  # chained by synthetic edges that mirror `run_fork/2`. Nothing below this point
  # knows an iteration node from a plain one.
  @body_keys ["process", "body"]
  @post_key "post_process"

  defp expand_bodies(%{nodes: nodes, edges: edges}) do
    expanded = Enum.map(nodes, &expand_node/1)

    %{
      nodes: Enum.flat_map(expanded, fn {node, subs, _edges} -> [node | subs] end),
      edges: edges ++ Enum.flat_map(expanded, fn {_node, _subs, es} -> es end)
    }
  end

  # Returns `{node, sub_nodes, sub_edges}`. The body params are dropped from the node
  # itself: they are nodes now, and leaving them would count every reference twice —
  # once against the iteration node, once against the sub-step that actually reads it.
  defp expand_node(node) do
    case body_chain(node["params"]) do
      [] ->
        {node, [], []}

      chain ->
        name = node["name"]
        subs = Enum.map(chain, &sub_node(&1, name))

        stripped =
          node
          |> Map.update!("params", &Map.drop(&1, @body_keys ++ [@post_key]))
          |> Map.put("iterates", over(node))

        {stripped, subs, chain_edges(subs, node)}
    end
  end

  defp over(node), do: node["params"]["over"] || "items"

  defp body_chain(%{} = params) do
    body = Enum.find_value(@body_keys, [], &params[&1])

    (List.wrap(body) ++ List.wrap(params[@post_key]))
    |> Enum.filter(&(is_map(&1) and is_binary(&1["name"])))
  end

  defp body_chain(_params), do: []

  defp sub_node(sub, parent) do
    %{
      "name" => "#{parent}/#{sub["name"]}",
      "module" => sub["module"],
      "params" => sub["params"] || %{}
    }
  end

  # `run_fork/2` threads the fan-out unit through the sub-steps in order, each one
  # receiving only the previous one's result. So the head is fed by the iteration
  # node and every other link by its predecessor — a plain chain of unmapped edges,
  # which is already how `upstream_emits/2` reads a predecessor's output schema.
  defp chain_edges([head | rest], node) do
    pairs = Enum.zip([head | rest], rest)

    [edge(node["name"], head["name"], head_mapping(head, node))] ++
      Enum.map(pairs, fn {from, to} -> edge(from["name"], to["name"], %{}) end)
  end

  defp chain_edges([], _node), do: []

  defp edge(from, to, mapping),
    do: %{"from" => from, "to" => to, "mapping" => mapping, "condition" => nil}

  # What the fan-out delivers into the first sub-step, and under which key. The unit
  # is wrapped under the delivery `field` — authored on a `map` node, detected from
  # the first body module on a `Batch`. When neither states it the unit is merged in
  # flat, so every required field of that module is what arrives.
  defp head_mapping(head, node) do
    fields =
      case node["params"]["field"] || batch_field(head["module"]) do
        nil -> required_schema_fields(head["module"])
        field -> [field]
      end

    Map.new(fields, &{&1, "#{node["name"]}.#{over(node)}"})
  end

  defp batch_field(module) do
    with {:ok, mod} <- Action.resolve(module || ""),
         {:ok, {field, _mode}} <- Action.batch_field(mod) do
      to_string(field)
    else
      _ -> nil
    end
  end

  # An iteration node reads its collection from `over` (`"items"` for a `Batch`).
  # Nothing declares it — `Batch` has no schema — so it is stated here, and then
  # travels the same path as any schema-required field: satisfied by a mapping, by a
  # predecessor's output, or by the payload, and unsatisfiable when by none of them.
  defp iterated_field(node), do: List.wrap(node["iterates"])

  # -- needs --------------------------------------------------------------------

  # Every input need in the graph, as `%{node:, field:, source:, kind:}` — one per
  # edge mapping, param reference, unwritten schema-required field, and condition.
  defp needs(workflow) do
    %{nodes: nodes, edges: edges} = workflow |> graph() |> expand_bodies()
    names = MapSet.new(nodes, & &1["name"])
    emits = Map.new(nodes, &{&1["name"], MapSet.new(emitted_schema_fields(&1["module"]))})

    Enum.flat_map(nodes, &node_needs(&1, edges, names, emits)) ++
      Enum.flat_map(edges, &condition_needs/1)
  end

  # The need an edge condition reads, keyed `"from->to"` rather than by either
  # endpoint so it never shares a bucket with a node field of the same name.
  defp condition_needs(%{"condition" => %{"field" => field}} = edge) do
    [
      %{
        node: "#{edge["from"]}->#{edge["to"]}",
        field: field,
        source: field,
        kind: condition_kind(field, edge["from"]),
        expects: nil
      }
    ]
  end

  defp condition_needs(_edge), do: []

  # An edge leaving `start` reads the trigger payload whatever shape the field has
  # — nothing has run yet for it to read instead.
  defp condition_kind(_field, @start), do: :start

  # On any other edge only a `start.`-prefixed field reads the payload; everything
  # else reads the fact flowing along the edge.
  defp condition_kind(field, _from) do
    case String.split(field, ".") do
      [@start | [_ | _]] -> :start
      _ -> :step
    end
  end

  defp node_needs(node, edges, names, emits) do
    name = node["name"]
    incoming = Enum.filter(edges, &(&1["to"] == name))

    mapped = incoming |> Enum.flat_map(&Map.keys(&1["mapping"])) |> MapSet.new()
    pinned = pinned_params(node["params"])

    scope = %{
      names: names,
      local: MapSet.union(mapped, pinned),
      upstream: upstream_emits(incoming, emits),
      specs: Map.new(required_schema_field_specs(node["module"]))
    }

    edge_needs(incoming, name, scope) ++
      param_needs(node, name, scope) ++
      schema_needs(node, name, incoming, scope)
  end

  # The kind a node's field expects, or `nil` when the schema declares none.
  defp expects(scope, field), do: Map.get(scope.specs, field)

  # Names of the params that carry a value. A `nil` param pins nothing, so its
  # field stays unwritten.
  defp pinned_params(params) do
    params
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> MapSet.new(fn {key, _value} -> key end)
  end

  # Field names the steps feeding this node declare they return — readable at the
  # fact root whether or not a mapping names them.
  defp upstream_emits(incoming, emits) do
    incoming
    |> Enum.map(& &1["from"])
    |> Enum.reject(&(&1 == @start))
    |> Enum.reduce(MapSet.new(), &MapSet.union(&2, Map.get(emits, &1, MapSet.new())))
  end

  defp edge_needs(incoming, name, scope) do
    incoming
    |> Enum.flat_map(&Map.to_list(&1["mapping"]))
    |> Enum.map(fn {target, source} -> need(name, target, source, scope) end)
  end

  # Types a param only when the author wrote the reference alone; an interpolated one
  # resolves to a string whatever the payload holds.
  defp param_needs(node, name, scope) do
    params = node["params"] || %{}

    Enum.map(param_references(node), fn {field, source} ->
      scope =
        if Placeholders.lone_reference?(Map.get(params, field)),
          do: scope,
          else: %{scope | specs: %{}}

      need(name, field, source, scope)
    end)
  end

  # Needs for the required fields nothing else writes: from `start` on a node fed
  # only by `start`, from a predecessor emitting them otherwise. A node's own module
  # states most of them; an iteration node's collection is the one the graph states.
  defp schema_needs(node, name, incoming, scope) do
    entry? = Enum.all?(incoming, &(&1["from"] == @start))

    (required_schema_fields(node["module"]) ++ iterated_field(node))
    |> Enum.uniq()
    |> Enum.reject(&MapSet.member?(scope.local, &1))
    |> Enum.map(fn field ->
      expects = expects(scope, field)

      cond do
        entry? ->
          %{
            node: name,
            field: field,
            source: qualified_start(field),
            kind: :start,
            expects: expects
          }

        MapSet.member?(scope.upstream, field) ->
          %{node: name, field: field, source: field, kind: :step, expects: expects}

        true ->
          %{node: name, field: field, source: nil, kind: :unsatisfiable, expects: expects}
      end
    end)
  end

  # Builds one need, classifying its source: a leading `start` is the trigger
  # payload, anything else is resolved against the graph by its root.
  defp need(node, field, source, scope) do
    kind =
      case String.split(source, ".") do
        [@start | [_ | _]] -> :start
        [root | _] -> root_kind(root, scope)
      end

    %{node: node, field: field, source: source, kind: kind, expects: expects(scope, field)}
  end

  # A source root is `:step` when it names a node, a locally written field, or a
  # field a predecessor emits; anything else has no producer in the graph.
  defp root_kind(root, %{names: names, local: local, upstream: upstream}) do
    if MapSet.member?(names, root) or MapSet.member?(local, root) or
         MapSet.member?(upstream, root),
       do: :step,
       else: :unsatisfiable
  end

  defp qualify(%{node: node, field: field}), do: "#{node}.#{field}"
  defp qualified_start(field), do: "#{@start}.#{field}"

  # -- param references ---------------------------------------------------------

  # Every `{{...}}` reference in a node's params, as `{param_field, source}` pairs.
  # One param may hold several references.
  defp param_references(%{"params" => params}) do
    Enum.flat_map(params, fn {field, value} ->
      value |> Placeholders.references() |> Enum.map(&{field, &1})
    end)
  end

  # -- schema -------------------------------------------------------------------

  @doc "Required field names of an action module's input schema, as strings."
  @spec required_schema_fields(String.t() | nil) :: [String.t()]
  def required_schema_fields(module),
    do: module |> required_schema_field_specs() |> Enum.map(&elem(&1, 0))

  @doc """
  Required fields of an action module's input schema, each with a spec that judges
  a candidate value for it — `[{name, spec}]`.

  A spec is a Zoi schema for that one field, whichever dialect the action declared —
  `Action.field_specs/1` reads both into that one vocabulary. Treat it as opaque.

  `required_schema_fields/1` is the names-only projection of this, so what the
  contract requires and what it type-checks cannot drift.
  """
  @spec required_schema_field_specs(String.t() | nil) :: [{String.t(), term()}]
  def required_schema_field_specs(module) do
    module
    |> Action.field_specs()
    |> Enum.filter(&elem(&1, 2))
    |> Enum.map(fn {name, spec, _required?} -> {name, spec} end)
  end

  @doc """
  Whether `value` satisfies a spec from `required_schema_field_specs/1`.

  Runs the value through `Zoi.parse/2` against the spec `Action.field_specs/1` read
  off the action, which is exactly what `StepRunner.validate_params/2` does to the
  same field at run time — so a verdict here is the verdict the run would reach.
  A `nil` value never satisfies a spec: presence is `check/2`'s question, and a
  field that reads `nil` at run time has no value at all.
  """
  @spec spec_accepts?(term(), term()) :: boolean()
  def spec_accepts?(_spec, nil), do: false
  def spec_accepts?(spec, value), do: match?({:ok, _}, Zoi.parse(spec, value))

  @doc """
  Field names an action module's output schema declares, as strings.

  Optional output fields count: the graph states a producer exists, and whether it
  returns the key on a given run is the action's own branch, not a gap in the graph.

  Read through `Action.output_field_specs/1`, the mirror of the reader the input side
  uses, so this module holds no schema-dialect knowledge of its own.
  """
  @spec emitted_schema_fields(String.t() | nil) :: [String.t()]
  def emitted_schema_fields(module),
    do: module |> Action.output_field_specs() |> Enum.map(&elem(&1, 0))

  # -- normalisation ------------------------------------------------------------

  # Normalises a workflow struct or a reloaded JSONB snapshot into string-keyed
  # nodes and edges.
  defp graph(%Workflow{nodes: nodes, edges: edges}) do
    %{
      nodes:
        Enum.map(
          nodes || [],
          &%{"name" => &1.name, "module" => &1.module, "params" => stringify(&1.params || %{})}
        ),
      edges:
        Enum.map(
          edges || [],
          &%{
            "to" => &1.to,
            "from" => &1.from,
            "mapping" => mapping(&1.mapping),
            "condition" => condition(&1.condition)
          }
        )
    }
  end

  defp graph(%{} = snapshot) do
    snapshot = stringify(snapshot)

    %{
      nodes: snapshot |> Map.get("nodes", []) |> Enum.map(&default(&1, "params")),
      edges:
        snapshot
        |> Map.get("edges", [])
        |> Enum.map(
          &(&1
            |> Map.put("mapping", mapping(&1["mapping"]))
            |> Map.put("condition", condition(&1["condition"])))
        )
    }
  end

  defp default(map, key), do: Map.put(map, key, Map.get(map, key) || %{})

  # Keeps only the `field` of an edge condition — the sole reference in it, since
  # `value` is the literal it is compared against.
  defp condition(%{} = condition) do
    case stringify(condition) do
      %{"field" => field} when is_binary(field) -> %{"field" => field}
      _ -> nil
    end
  end

  defp condition(_condition), do: nil

  # Stringifies both sides of an edge mapping: the target field name and the
  # dotted source reference.
  defp mapping(mapping) when is_map(mapping) do
    for {target, source} <- mapping,
        reference?(source),
        into: %{},
        do: {to_string(target), to_string(source)}
  end

  defp mapping(_mapping), do: %{}

  # A mapping source is a dotted reference, so anything non-scalar in the persisted
  # JSONB is a malformed edge. Dropping it leaves the target field unfed, which the
  # derivation then reports as a gap — the point of this module is to be runnable
  # against a graph that is wrong, not to raise `Protocol.UndefinedError` on one.
  defp reference?(source) when is_binary(source) or is_number(source), do: true
  defp reference?(source) when is_atom(source), do: not is_nil(source)
  defp reference?(_source), do: false

  defp stringify(%{__struct__: _} = value), do: value

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {to_string(k), stringify(v)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value), do: value
end
