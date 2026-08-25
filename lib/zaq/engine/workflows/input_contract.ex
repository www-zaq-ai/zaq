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
  `required_inputs/1` as the payload itself — a nested skeleton with `nil` leaves.

  A dotted path is a *shape*, not a key: `"input.name"` means the payload carries
  an `"input"` object holding `"name"`. Callers fill values into the skeleton
  instead of applying that convention themselves.

      %{"email topic" => nil, "input" => %{"name" => nil}}

  Where a path is both a leaf and a prefix of another (`"input"` and
  `"input.name"`), the nested form wins — it satisfies both.
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
  canonicalising fallback accepts `"Email_Topic"` for `"email topic"`. A key
  present but `nil` counts as supplied; only an unresolvable path is missing.
  """
  @spec check(Workflow.t() | map() | [String.t()], term()) :: %{
          valid: boolean(),
          supplied: [String.t()],
          missing_inputs: [String.t()]
        }
  def check(required, payload) when is_list(required) do
    fact = %{__cascade__: %{start: payload}}

    {supplied, missing} =
      Enum.split_with(required, &match?({:ok, _}, FactLookup.fetch(fact, qualified_start(&1))))

    %{valid: missing == [], supplied: Enum.sort(supplied), missing_inputs: Enum.sort(missing)}
  end

  def check(workflow, payload), do: workflow |> required_inputs() |> check(payload)

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
          required_inputs: [String.t()],
          required_input_shape: map(),
          unsatisfiable_inputs: [
            %{node: String.t(), field: String.t(), source: String.t() | nil}
          ]
        }
  def contract(workflow, payload) do
    needs = needs(workflow)
    required = required_inputs_from(needs)
    verdict = check(required, payload)

    %{
      valid: verdict.valid,
      missing_inputs: verdict.missing_inputs,
      required_inputs: required,
      required_input_shape: shape(required),
      unsatisfiable_inputs: unsatisfiable_from(needs)
    }
  end

  # -- needs --------------------------------------------------------------------

  # Every input need in the graph, as `%{node:, field:, source:, kind:}` — one per
  # edge mapping, param reference, unwritten schema-required field, and condition.
  defp needs(workflow) do
    %{nodes: nodes, edges: edges} = graph(workflow)
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
        kind: condition_kind(field, edge["from"])
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
      upstream: upstream_emits(incoming, emits)
    }

    edge_needs(incoming, name, scope) ++
      param_needs(node, name, scope) ++
      schema_needs(node, name, incoming, scope)
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

  defp param_needs(node, name, scope) do
    Enum.map(param_references(node), fn {field, source} ->
      need(name, field, source, scope)
    end)
  end

  # Needs for the schema-required fields nothing else writes: from `start` on a
  # node fed only by `start`, from a predecessor emitting them otherwise.
  defp schema_needs(node, name, incoming, scope) do
    entry? = Enum.all?(incoming, &(&1["from"] == @start))

    node["module"]
    |> required_schema_fields()
    |> Enum.reject(&MapSet.member?(scope.local, &1))
    |> Enum.map(fn field ->
      cond do
        entry? ->
          %{node: name, field: field, source: qualified_start(field), kind: :start}

        MapSet.member?(scope.upstream, field) ->
          %{node: name, field: field, source: field, kind: :step}

        true ->
          %{node: name, field: field, source: nil, kind: :unsatisfiable}
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

    %{node: node, field: field, source: source, kind: kind}
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
  def required_schema_fields(module) do
    with {:ok, mod} <- Action.resolve(module || ""),
         true <- function_exported?(mod, :schema, 0) do
      mod.schema() |> schema_fields() |> Enum.filter(&elem(&1, 1)) |> Enum.map(&elem(&1, 0))
    else
      _ -> []
    end
  end

  @doc """
  Field names an action module's output schema declares, as strings.

  Optional output fields count: the graph states a producer exists, and whether it
  returns the key on a given run is the action's own branch, not a gap in the graph.
  """
  @spec emitted_schema_fields(String.t() | nil) :: [String.t()]
  def emitted_schema_fields(module) do
    with {:ok, mod} <- Action.resolve(module || ""),
         true <- function_exported?(mod, :output_schema, 0) do
      mod.output_schema() |> schema_fields() |> Enum.map(&elem(&1, 0))
    else
      _ -> []
    end
  end

  # Reads `{name, required?}` pairs out of either schema dialect: a `Zoi.object`
  # struct or a NimbleOptions keyword list.
  defp schema_fields(%{fields: fields}) when is_list(fields),
    do: Enum.map(fields, fn {name, type} -> {to_string(name), type.meta.required == true} end)

  defp schema_fields(schema) when is_list(schema),
    do:
      Enum.map(schema, fn {name, opts} ->
        {to_string(name), Keyword.get(opts, :required) == true}
      end)

  defp schema_fields(_schema), do: []

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
  defp mapping(mapping) when is_map(mapping),
    do: Map.new(mapping, fn {target, source} -> {to_string(target), to_string(source)} end)

  defp mapping(_mapping), do: %{}

  defp stringify(%{__struct__: _} = value), do: value

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {to_string(k), stringify(v)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value), do: value
end
