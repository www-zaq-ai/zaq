defmodule Zaq.Engine.Workflows.InputContract do
  @moduledoc """
  Derives what a workflow's trigger payload must carry, and judges a candidate one.

  A workflow is a DAG of nodes wired by edges. Every node needs input fields; some
  are written by an upstream step, and the rest must arrive in the trigger payload.
  This module walks the graph — edge mappings, `{{...}}` references in node params,
  edge conditions — and reads each action's `schema/0` and `output_schema/0` for what
  it declares, to sort one from the other. `start` names the trigger payload: it is
  not a node, so a field sourced from `start.*` is never step-fed.

  `contract/2` is the entry point. It judges a payload and returns the verdict,
  nothing else:

      %{
        valid?: false,
        errors: [
          %{path: ["email topic"], code: :required, message: "is required",
            expected: %{"type" => "string", "minLength" => 3}},
          %{path: ["input", "name"], code: :invalid_type,
            message: "expected string, got integer",
            expected: %{"type" => "string"}}
        ]
      }

  One entry per problem, carrying where to fix it, a `code` in Zoi's vocabulary
  (`:required` for the key, `:invalid_type` for the kind, anything else for a rule
  the author declared), a sentence, and `expected` — what that path accepts, as JSON
  Schema, so the rule travels with the refusal. `valid?` is `errors == []`. A `path` is a
  list of segments rather than a dotted string, so it cannot be misread as a flat
  key, and a list index (`["rows", 0, "email"]`) has a spelling at all.

  Describing a workflow — what it *can* be sent — is a different question, answered
  by `required_inputs/1`, `optional_inputs/1`, `input_types/1` and
  `required_input_shape/1`. They walk the same graph; they are not part of the
  verdict.

  Rationale, and the run-time parity argument, live in `docs/services/workflows.md`.
  """

  alias Zaq.Engine.Workflows.Action
  alias Zaq.Engine.Workflows.FactLookup
  alias Zaq.Engine.Workflows.Placeholders
  alias Zaq.Engine.Workflows.Workflow

  @start "start"

  # Every input field every node needs, as `"node.field"`. A node needs a field when an
  # edge mapping writes it, a reference in its own params reads it, or its schema requires
  # it and nothing else supplies it. An edge condition is keyed by the edge
  # (`"from->to.field"`), writing into neither endpoint.
  defp all_inputs_from(needs), do: MapSet.new(needs, &qualify/1)

  # The inputs fed by the output of a previous step. Fed only when *every* source writing
  # into it names another node; one `start.*` source is the trigger payload, so it is
  # enough to make the field unfed.
  defp fed_by_steps_from(needs) do
    needs
    |> Enum.group_by(&qualify/1)
    |> Enum.filter(fn {_field, needs} -> Enum.all?(needs, &(&1.kind == :step)) end)
    |> MapSet.new(fn {field, _needs} -> field end)
  end

  # Every input the graph needs minus the ones a previous step feeds — what the trigger
  # payload is left owing.
  defp missing_from(needs),
    do: MapSet.difference(all_inputs_from(needs), fed_by_steps_from(needs))

  @doc """
  The paths the trigger payload must carry, as dotted strings.

  The unfed inputs translated into what a caller can send: the `start.*` sources behind
  each unfed field, prefix stripped and duplicates collapsed. A path reaching only
  fields the schemas declare optional is in `optional_inputs/1` instead.
  """
  @spec required_inputs(Workflow.t() | map()) :: [String.t()]
  def required_inputs(workflow), do: workflow |> needs() |> required_inputs_from()

  @doc """
  The paths the trigger payload *may* carry, as dotted strings.

  The unfed `start.*` sources reaching only fields their action declares optional:
  the graph wires them, but every step still runs when the payload omits one. A path
  reaching an optional field on one node and a required field on another is required.

  Optional is about presence, not type — a wired optional field is typed like any
  other, and `contract/2` judges the ones a payload supplies.
  """
  @spec optional_inputs(Workflow.t() | map()) :: [String.t()]
  def optional_inputs(workflow), do: workflow |> needs() |> optional_inputs_from()

  defp required_inputs_from(needs), do: needs |> start_paths() |> paths_where(true)

  defp optional_inputs_from(needs), do: needs |> start_paths() |> paths_where(false)

  # The unfed payload paths the graph reads, grouped as `%{path => [need]}`. One path
  # can reach several fields, and each has its own say in whether the payload owes it.
  defp start_paths(needs) do
    unfed = missing_from(needs)

    needs
    |> Enum.filter(&(&1.kind == :start and qualify(&1) in unfed))
    |> Enum.group_by(&String.replace_prefix(&1.source, @start <> ".", ""))
  end

  # A path is required as soon as one field it reaches requires it: every node runs,
  # so an omission that starves any one of them starves the run.
  defp paths_where(paths, required?) do
    paths
    |> Enum.filter(fn {_path, needs} -> Enum.any?(needs, & &1.required?) == required? end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  # The payload paths that carry a declared type, as `%{path => [spec]}`. A path is typed
  # only where its value reaches a schema-declared field whole — a mapping target, a
  # schema-required field of an entry node, or a param written as a lone `{{...}}`.
  # A path several nodes read collects one spec per node: the value must satisfy all.
  defp expectations_from(needs) do
    unfed = missing_from(needs)

    needs
    |> Enum.filter(&(&1.kind == :start and &1.expects != nil and qualify(&1) in unfed))
    |> Enum.group_by(&String.replace_prefix(&1.source, @start <> ".", ""), & &1.expects)
    |> Map.new(fn {path, specs} -> {path, Enum.uniq(specs)} end)
  end

  @doc """
  The declared kind of every payload path, as `%{path => kind}`.

  The declared specs rendered for a reader: one entry per path in `required_inputs/1`
  and `optional_inputs/1`, named through `Action.schema_kind/1` (`"integer"`,
  `"one of: active, inactive"`).

  Every path appears — an untyped one reads `"any"` rather than being left out, so a
  reader never has to guess. A path several nodes read names every kind it must
  satisfy at once (`"integer and one of: 1, 2"`).
  """
  @spec input_types(Workflow.t() | map()) :: %{String.t() => String.t()}
  def input_types(workflow), do: workflow |> needs() |> input_types_from()

  defp input_types_from(needs) do
    expectations = expectations_from(needs)
    paths = required_inputs_from(needs) ++ optional_inputs_from(needs)

    Map.new(paths, fn path ->
      case expectations |> Map.get(path, []) |> Enum.map(&Action.schema_kind/1) |> Enum.uniq() do
        [] -> {path, "any"}
        kinds -> {path, Enum.join(kinds, " and ")}
      end
    end)
  end

  @doc """
  `required_inputs/1` as the payload itself — a nested skeleton with `nil` leaves.

      %{"email topic" => nil, "input" => %{"name" => nil}}

  A dotted path is a *shape*, not a key. Where a path is both a leaf and a prefix of
  another, the nested form wins. Not a payload: `contract/2` counts a `nil` leaf as
  missing, so the skeleton is invalid on every path it names.
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
  Judges a candidate trigger payload, as `%{valid?:, errors:}`.

  Resolution goes through `FactLookup` with the payload planted under `start`, so a path matches the
  way it will at run time — nested paths descend, and `"Email_Topic"` resolves
  `"email topic"`.

  Each entry carries a Zoi `code`: `:required` (the path is absent or resolves to
  `nil`), `:invalid_type`, or a rule the author declared (`:invalid_length`,
  `:invalid_enum_value`, …) with Zoi's own phrasing and path kept. `false`, `0` and
  `""` are values a caller can mean, and supply. An optional path is an error only
  when it is present and wrong.

  Takes a workflow: the graph is what makes the verdict more than a presence test.

  This is the name `Workflows.input_contract/2` dispatches.
  """
  @spec contract(Workflow.t() | map(), term()) :: %{
          valid?: boolean(),
          errors: [
            %{
              path: [String.t() | integer()],
              code: atom(),
              message: String.t(),
              expected: map()
            }
          ]
        }
  def contract(workflow, payload) do
    needs = needs(workflow)

    check_against(
      required_inputs_from(needs),
      optional_inputs_from(needs),
      expectations_from(needs),
      payload
    )
  end

  defp check_against(required, optional, expectations, payload) do
    fact = %{__cascade__: %{start: payload}}

    {supplied, missing} =
      required
      |> Enum.map(&{&1, FactLookup.fetch(fact, qualified_start(&1))})
      |> Enum.split_with(&match?({_path, {:ok, value}} when not is_nil(value), &1))

    # An optional path the payload omits is not a gap; one it carries is judged like
    # any other.
    present_optional =
      optional
      |> Enum.map(&{&1, FactLookup.fetch(fact, qualified_start(&1))})
      |> Enum.filter(&match?({_path, {:ok, value}} when not is_nil(value), &1))

    errors =
      Enum.map(missing, fn {path, _fetched} -> required_error(path, expectations) end) ++
        Enum.flat_map(supplied ++ present_optional, &value_errors(&1, expectations))

    errors = errors |> Enum.uniq() |> Enum.sort_by(& &1.path)

    %{valid?: errors == [], errors: errors}
  end

  defp required_error(path, expectations) do
    segments = segments(path)

    segments
    |> List.last()
    |> Zoi.Error.required(path: segments)
    |> Action.error_json()
    |> with_expected(path, expectations)
  end

  # Every error names what the path accepts, so a caller fixing one has the rule in
  # front of it rather than in a second lookup. It matters most on a `:required` entry:
  # "is required" is the same sentence for every missing path, and without this the
  # verdict says which keys are absent and nothing about what they take.
  defp with_expected(error, path, expectations) do
    Map.put(error, :expected, Action.schema_json(Map.get(expectations, path, [])))
  end

  # Every rule the value breaks, at the path the payload carries it under. Zoi's own
  # path is lifted onto it, so a nested failure reads as `["input", "name", "email"]`.
  defp value_errors({path, {:ok, value}}, expectations) do
    segments = segments(path)

    expectations
    |> Map.get(path, [])
    |> Enum.flat_map(&Action.field_errors(&1, value))
    |> Enum.map(
      &(&1
        |> Zoi.Error.prepend_path(segments)
        |> Action.error_json()
        |> with_expected(path, expectations))
    )
  end

  defp segments(path), do: String.split(path, ".")

  # -- iteration bodies ---------------------------------------------------------

  # An iteration node (`Batch`, or the `map` it lowers to) declares its sub-pipeline
  # inline as params and has no schema of its own — the body modules declare what it
  # needs. So the body is lifted into the graph first: one node per sub-step, named
  # `"<node>/<sub>"` as `MapNodeBuilder` names its StepRuns, chained by synthetic edges.
  # Nothing below this point knows an iteration node from a plain one.
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
  # itself — they are nodes now, and leaving them would count every reference twice.
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

  # `run_fork/2` threads the unit through the sub-steps in order, each receiving only
  # the previous one's result — so the body is a plain chain of unmapped edges.
  defp chain_edges([head | rest], node) do
    pairs = Enum.zip([head | rest], rest)

    [edge(node["name"], head["name"], head_mapping(head, node))] ++
      Enum.map(pairs, fn {from, to} -> edge(from["name"], to["name"], %{}) end)
  end

  defp chain_edges([], _node), do: []

  # `"synthetic"` marks an edge this module invented to model the fan-out. `run_fork/2`
  # merges the unit *under* the sub-step's own params, the opposite precedence to a real
  # edge, so a body param keeps the value its author wrote.
  defp edge(from, to, mapping),
    do: %{
      "from" => from,
      "to" => to,
      "mapping" => mapping,
      "condition" => nil,
      "synthetic" => true
    }

  # What the fan-out delivers into the first sub-step, and under which key — authored
  # on a `map` node, detected from the first body module on a `Batch`. When neither
  # states it, the unit is merged in flat.
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

  # An iteration node reads its collection from `over` (`"items"` for a `Batch`). No
  # schema declares it, so it is stated here and then travels the same path as any
  # schema-required field.
  defp iterated_field(node), do: List.wrap(node["iterates"])

  # No schema declares an iteration node's collection — `Batch` has none, and a `map`
  # node names its own in `over` — so it is the one required field nothing could type.
  # It is always a list: `MapNodeBuilder.extract_items/6` wraps whatever it finds with
  # `List.wrap/1`, so a scalar does not fail there, it silently fans out as one item.
  defp iterated_specs(node),
    do: Map.new(iterated_field(node), &{&1, {Zoi.array(Zoi.any()), true}})

  # -- needs --------------------------------------------------------------------

  # Every input need in the graph, as `%{node:, field:, source:, kind:}` — one per
  # edge mapping, param reference, unwritten schema-required field, and condition.
  defp needs(workflow) do
    %{nodes: nodes, edges: edges} = workflow |> graph() |> expand_bodies()
    ancestors = ancestors(edges)
    emits = Map.new(nodes, &{&1["name"], MapSet.new(emitted_schema_fields(&1["module"]))})

    Enum.flat_map(nodes, &node_needs(&1, edges, ancestors, emits)) ++
      Enum.flat_map(edges, &condition_needs/1)
  end

  # Every node that runs before each node, as `%{node => MapSet.t()}`. The cascade is
  # built per path (`StepRunner.inject_cascade/3`), so a node on another branch is never
  # in this node's fact. `start` is not a node and is dropped.
  defp ancestors(edges) do
    parents =
      edges
      |> Enum.reject(&(&1["from"] == @start))
      |> Enum.group_by(& &1["to"], & &1["from"])

    Enum.reduce(Map.keys(parents), %{}, &walk_ancestors(&2, &1, parents, %{}))
  end

  # Depth-first, memoised in the accumulator. `visiting` guards a cycle: a persisted
  # workflow is acyclic, but this module runs against graphs that are wrong. It is a
  # plain map, not a `MapSet` — threading an opaque type through the recursion loses
  # its opaqueness and Dialyzer then flags every use of it.
  defp walk_ancestors(acc, node, parents, visiting) do
    if Map.has_key?(acc, node) or Map.has_key?(visiting, node) do
      acc
    else
      forebears = Map.get(parents, node, [])
      visiting = Map.put(visiting, node, true)
      acc = Enum.reduce(forebears, acc, &walk_ancestors(&2, &1, parents, visiting))

      Map.put(acc, node, collect_ancestors(forebears, acc))
    end
  end

  defp collect_ancestors(forebears, acc) do
    Enum.reduce(forebears, MapSet.new(), fn parent, set ->
      set |> MapSet.put(parent) |> MapSet.union(Map.get(acc, parent, MapSet.new()))
    end)
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
        expects: nil,
        required?: true
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

  defp node_needs(node, edges, ancestors, emits) do
    name = node["name"]
    incoming = Enum.filter(edges, &(&1["to"] == name))

    mapped = incoming |> Enum.flat_map(&Map.keys(&1["mapping"])) |> MapSet.new()
    pinned = pinned_params(node["params"])

    scope = %{
      ancestors: Map.get(ancestors, name, MapSet.new()),
      overwritten: overwritten(incoming),
      local: MapSet.union(mapped, pinned),
      upstream: upstream_emits(incoming, emits),
      specs: Map.merge(declared_field_specs(node["module"]), iterated_specs(node)),
      typed?: true
    }

    edge_needs(incoming, name, scope) ++
      param_needs(node, name, scope) ++
      schema_needs(node, name, incoming, scope)
  end

  # Every declared field of a module's schema, `%{name => {spec, required?}}`, optional
  # ones included: `required?` whether the payload must carry it, `spec` what it accepts.
  defp declared_field_specs(module) do
    module
    |> Action.field_specs()
    |> Map.new(fn {name, spec, required?} -> {name, {spec, required?}} end)
  end

  # The kind a node's field expects, or `nil` when the schema declares none or the
  # value reaches the field interpolated rather than whole.
  defp expects(%{typed?: false}, _field), do: nil

  defp expects(scope, field) do
    case Map.get(scope.specs, field) do
      {spec, _required?} -> spec
      nil -> nil
    end
  end

  # Whether the payload must carry the field. A field no schema declares is unknown,
  # and unknown counts as required.
  defp field_required?(scope, field) do
    case Map.get(scope.specs, field) do
      {_spec, required?} -> required?
      nil -> true
    end
  end

  # Param keys an incoming edge overwrites at run time. Only a real edge does — the
  # mapped value wins the merge, so what the author wrote never reaches the action.
  defp overwritten(incoming) do
    incoming
    |> Enum.reject(& &1["synthetic"])
    |> Enum.flat_map(&Map.keys(&1["mapping"]))
    |> MapSet.new()
  end

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
  # resolves to a string whatever the payload holds. A param a real incoming edge
  # overwrites is skipped — `StepRunner.still_authored/2` never resolves it, so asking
  # the payload for what it names would starve a caller for a value the run ignores.
  # A synthetic body edge merges the other way (see `edge/3`), so its reference stands.
  defp param_needs(node, name, scope) do
    params = node["params"] || %{}

    node
    |> param_references()
    |> Enum.reject(fn {field, _source} -> MapSet.member?(scope.overwritten, field) end)
    |> Enum.map(fn {field, source} ->
      typed? = Placeholders.lone_reference?(Map.get(params, field))

      need(name, field, source, %{scope | typed?: typed?})
    end)
  end

  # Needs for the required fields nothing else writes: from `start` on a node fed only
  # by `start`, from a predecessor emitting them otherwise.
  defp schema_needs(node, name, incoming, scope) do
    entry? = Enum.all?(incoming, &(&1["from"] == @start))

    (required_specs(scope) ++ iterated_field(node))
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
            expects: expects,
            required?: true
          }

        MapSet.member?(scope.upstream, field) ->
          %{
            node: name,
            field: field,
            source: field,
            kind: :step,
            expects: expects,
            required?: true
          }

        true ->
          %{
            node: name,
            field: field,
            source: nil,
            kind: :unsatisfiable,
            expects: expects,
            required?: true
          }
      end
    end)
  end

  # The required field names of the node's own schema, read off the specs `node_needs/4`
  # already loaded — `Action.field_specs/1` rebuilds the schema struct on every call.
  # Sorted because `scope.specs` is a map and loses declaration order.
  defp required_specs(scope) do
    scope.specs
    |> Enum.filter(fn {_name, {_spec, required?}} -> required? end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  # Builds one need, classifying its source: a leading `start` is the trigger
  # payload, anything else is resolved against the graph by its root.
  defp need(node, field, source, scope) do
    kind =
      case String.split(source, ".") do
        [@start | [_ | _]] -> :start
        [root | _] -> root_kind(root, scope)
      end

    %{
      node: node,
      field: field,
      source: source,
      kind: kind,
      expects: expects(scope, field),
      required?: field_required?(scope, field)
    }
  end

  # A source root is `:step` when it names a node that runs before this one, a locally
  # written field, or a field a predecessor emits. Anything else is `:unsatisfiable`:
  # the fact will not carry it. That kind is not reported — it only keeps a dangling
  # source from counting as step-fed; naming a broken graph is `Composition`'s job.
  defp root_kind(root, %{ancestors: ancestors, local: local, upstream: upstream}) do
    if MapSet.member?(ancestors, root) or MapSet.member?(local, root) or
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

  # Required field names of an action module's input schema, as strings.
  @spec required_schema_fields(String.t() | nil) :: [String.t()]
  defp required_schema_fields(module),
    do: module |> required_schema_field_specs() |> Enum.map(&elem(&1, 0))

  # Required fields of an action module's input schema, each with a spec that judges a
  # candidate value for it — `[{name, spec}]`. A spec is a Zoi schema for that one field,
  # whichever dialect the action declared. `required_schema_fields/1` is the names-only
  # projection.
  @spec required_schema_field_specs(String.t() | nil) :: [{String.t(), term()}]
  defp required_schema_field_specs(module) do
    module
    |> Action.field_specs()
    |> Enum.filter(&elem(&1, 2))
    |> Enum.map(fn {name, spec, _required?} -> {name, spec} end)
  end

  # Field names an action module's output schema declares, as strings. Optional output
  # fields count: whether a run returns the key is the action's own branch, not a gap in
  # the graph.
  @spec emitted_schema_fields(String.t() | nil) :: [String.t()]
  defp emitted_schema_fields(module),
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
  # JSONB is a malformed edge. Dropping it leaves the field unfed, reported as a gap —
  # this module runs against graphs that are wrong rather than raising on them.
  defp reference?(source) when is_binary(source) or is_number(source), do: true
  defp reference?(source) when is_atom(source), do: not is_nil(source)
  defp reference?(_source), do: false

  defp stringify(%{__struct__: _} = value), do: value

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {to_string(k), stringify(v)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value), do: value
end
