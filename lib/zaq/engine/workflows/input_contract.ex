defmodule Zaq.Engine.Workflows.InputContract do
  @moduledoc """
  Derives what a workflow's trigger payload must contain.

      missing = all_inputs − fed_by_steps

  `start` is not a step, so an input fed from the `start` namespace is never in
  `fed_by_steps` and always survives the difference. That is the "except start"
  clause — it falls out of the definition rather than being special-cased.

  Every element of both sets is a `"node.field"` string, so two nodes needing a
  field of the same name stay distinct and the sets are directly comparable.

  The graph states routing; the action modules it names state requirements
  (`schema/0`) and guarantees (`output_schema/0`). Both are read, so a field is
  fed whenever a predecessor declares it — `StepRunner` passes the whole fact
  down the edge, so an unmapped edge still carries the predecessor's output.
  What satisfies neither is not unknown, it is `unsatisfiable_inputs/1`.
  """

  alias Zaq.Engine.Workflows.Action
  alias Zaq.Engine.Workflows.FactLookup
  alias Zaq.Engine.Workflows.Workflow

  @start "start"

  @doc """
  Every input field every node needs, as `"node.field"`.

  A node needs a field when an incoming edge mapping writes it, when a reference
  inside its own params reads it, or when its action schema requires it and
  nothing else supplies it.

  An edge condition needs the field it gates on. It writes nothing into either
  endpoint, so it is keyed by the edge (`"from->to.field"`) rather than by a node.
  """
  @spec all_inputs(Workflow.t() | map()) :: MapSet.t(String.t())
  def all_inputs(workflow), do: workflow |> needs() |> all_inputs_from()

  defp all_inputs_from(needs), do: MapSet.new(needs, &qualify/1)

  @doc """
  The inputs fed by the output of a previous step, as `"node.field"`.

  A field is fed when **every** source that writes into it names another node.
  A `start.*` source is the trigger payload, not a step output, so a field with
  even one `start` source is not fed and survives the difference — that is the
  "except start" clause.
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
  an `"input"` object holding `"name"`, because that is how `FactLookup` resolves
  it at run time. A caller reading the flat list has to know that convention and
  apply it; a caller reading this fills values into a structure that is already
  correct.

      %{"email topic" => nil, "input" => %{"name" => nil}}

  Where a path is both a leaf and a prefix of another (`"input"` and
  `"input.name"`), the nested form wins — it satisfies both.
  """
  @spec required_input_shape(Workflow.t() | map()) :: map()
  def required_input_shape(workflow), do: workflow |> required_inputs() |> shape()

  defp shape(required),
    do: Enum.reduce(required, %{}, &put_path(&2, String.split(&1, ".")))

  # A leaf never overwrites a branch already placed at the same key, and a branch
  # always replaces a leaf — so the deeper path wins whichever order they arrive.
  defp put_path(shape, [leaf]), do: Map.put_new(shape, leaf, nil)

  defp put_path(shape, [segment | rest]) do
    nested = if is_map(shape[segment]), do: shape[segment], else: %{}
    Map.put(shape, segment, put_path(nested, rest))
  end

  @doc """
  Inputs no step can feed and no payload can supply, as `%{node:, field:, source:}`.

  A field is unsatisfiable when nothing local writes it, no predecessor's output
  schema declares it, and it is not rooted in `start` — so the graph names a
  source that has no producer. `source` is that dangling reference, or `nil` when
  the field is schema-required and the graph names nothing at all.

  This is an authoring error, not a payload gap: the run reads `nil` and fails
  silently. Folding it into `missing/1` would instead claim the payload must
  supply something no node would ever read.
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

  Resolution goes through `FactLookup` with the payload planted under `start`, so
  a path matches exactly the way it will at run time: nested paths descend, and
  the canonicalising fallback accepts `"Email_Topic"` for `"email topic"`. A key
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

  Every field here is derivable from the public functions above, but each of those
  rebuilds the graph and re-resolves every action module's schema. This derives
  `needs/1` once and reads all five off it, so a caller that wants the full picture
  pays for one traversal instead of one per field.
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

  # One need is "node.field is written from source". Three things write a field:
  # an incoming edge mapping, a reference inside the node's own params, and — when
  # neither does — the action schema requiring it.
  #
  # An edge condition is a fourth reader. It writes nothing, but it reads a field
  # to decide whether the edge fires, and a `start.*` condition is the author
  # stating the trigger payload carries that field.
  defp needs(workflow) do
    %{nodes: nodes, edges: edges} = graph(workflow)
    names = MapSet.new(nodes, & &1["name"])
    emits = Map.new(nodes, &{&1["name"], MapSet.new(emitted_schema_fields(&1["module"]))})

    Enum.flat_map(nodes, &node_needs(&1, edges, names, emits)) ++
      Enum.flat_map(edges, &condition_needs/1)
  end

  # A condition need is keyed by the edge, not by either endpoint. Keying it on the
  # target would put it in the same `"node.field"` bucket as a mapping writing a
  # field of the same name, and `fed_by_steps/1` requires *every* need in a bucket
  # to be step-sourced — so an unrelated mapping would cancel the condition's need,
  # or the condition's would strand the mapping's field.
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

  # Nothing has run when a `from: "start"` edge is evaluated: the cascade holds only
  # `start` and the raw payload also sits at the fact root, so every field such an
  # edge reads — bare, dotted, or `start.`-prefixed — resolves to the trigger
  # payload. There is no step to attribute it to.
  defp condition_kind(_field, @start), do: :start

  # On every other edge `EdgeStep` resolves the field through `FactLookup` against
  # the fact flowing along it, so anything not rooted in `start` reads that fact —
  # the source node's own output, or a step named in the cascade. Unlike `need/5`,
  # a bare root here is never untraceable: the step the edge leaves feeds it.
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

  # A param pins a field only when it carries a value. `nil` is never one, so a key
  # present with `nil` leaves the field unwritten rather than silently satisfying a
  # required field the run would then read as `nil`. An empty string, map or list is
  # left alone — those are values an author can mean.
  defp pinned_params(params) do
    params
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> MapSet.new(fn {key, _value} -> key end)
  end

  # What the steps feeding this node declare they return. `StepRunner` passes the
  # whole fact down the edge, so a predecessor's output key is readable at the
  # fact root whether or not a mapping names it.
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
    Enum.map(param_references(node, scope.names), fn {field, source} ->
      need(name, field, source, scope)
    end)
  end

  # Only fields nothing else writes fall through to the schema. An entry node
  # reads the trigger payload flat at the fact root, so its unwritten required
  # fields come from `start`; a mid-DAG node's come from the predecessor whose
  # output schema declares them, and are unsatisfiable when none does.
  #
  # `start` is not a step, so an edge leaving it does not make the target mid-DAG:
  # a node fed only from `start` is still an entry node.
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

  # Classifies where a source reads from. A leading `start` is the trigger payload;
  # anything else is resolved against the graph by its root.
  defp need(node, field, source, scope) do
    kind =
      case String.split(source, ".") do
        [@start | [_ | _]] -> :start
        [root | _] -> root_kind(root, scope)
      end

    %{node: node, field: field, source: source, kind: kind}
  end

  # A root names a step when it is a node, when something local writes that key —
  # itself a need, already counted — or when a predecessor's output schema declares
  # it. Nothing left names a source the graph has no producer for.
  defp root_kind(root, %{names: names, local: local, upstream: upstream}) do
    if MapSet.member?(names, root) or MapSet.member?(local, root) or
         MapSet.member?(upstream, root),
       do: :step,
       else: :unsatisfiable
  end

  defp qualify(%{node: node, field: field}), do: "#{node}.#{field}"
  defp qualified_start(field), do: "#{@start}.#{field}"

  # -- param references ---------------------------------------------------------

  # Same placeholder class as `Concat` and `DispatchEvent`.
  @placeholder ~r/\{\{\s*([\w.][\w.\s-]*?)\s*\}\}/

  # Params of these modules are scanned for `{{...}}`; every other action receives
  # its params literally (`StepRunner` resolves edge mappings, never node params),
  # so a dotted string elsewhere is data, not a reference.
  #
  # `Condition` is deliberately absent: it substitutes no `{{...}}` at all. It
  # resolves a bare dotted `input` and each `conditions[].key` through
  # `FactLookup`, which `bare_references/3` covers. Listing it here could only
  # invent a requirement — a `{{x}}` in a Condition param stays a literal string
  # at run time, so no payload the agent sends would make the node work.
  @placeholder_sites %{
    "Zaq.Agent.Tools.Workflow.Concat" => ["parts"],
    "Zaq.Agent.Tools.Workflow.DispatchEvent" => ["input"],
    "Zaq.Agent.Tools.Workflow.RunAgent" => ["input", "context"]
  }

  @condition_module "Zaq.Agent.Tools.Workflow.Condition"

  # Returns `{field, source}` pairs, where `field` is the param the reference sits
  # in — several references may share one field, and the field is unfed unless all
  # of them are step-sourced.
  defp param_references(%{"module" => module, "params" => params}, names) do
    sites = Map.get(@placeholder_sites, module, [])

    placeholders =
      Enum.flat_map(sites, fn field ->
        params |> Map.get(field) |> placeholders() |> Enum.map(&{field, &1})
      end)

    placeholders ++ bare_references(module, params, names)
  end

  # `Condition` resolves a bare dotted `input` against the cascade — a reference
  # without any `{{}}`.
  defp bare_references(@condition_module, params, names) do
    input =
      case Map.get(params, "input") do
        ref when is_binary(ref) -> [{"input", ref}]
        _ -> []
      end

    keys =
      params
      |> Map.get("conditions")
      |> List.wrap()
      |> Enum.flat_map(fn condition ->
        case condition do
          %{"key" => key} when is_binary(key) -> [{"conditions", key}]
          _ -> []
        end
      end)
      |> Enum.filter(fn {_field, key} -> graph_reference?(key, names) end)

    input ++ keys
  end

  defp bare_references(_module, _params, _names), do: []

  # `Condition` evaluates each `conditions[].key` against the *resolved input map*
  # with `__cascade__` merged in, so only a key rooted at `start` or a node name
  # reaches the graph. Every other key is a path inside the input value — run-time
  # data the graph says nothing about, and not an input of the workflow.
  defp graph_reference?(key, names) do
    case String.split(key, ".") do
      [@start | [_ | _]] -> true
      [root | [_ | _]] -> MapSet.member?(names, root)
      _ -> false
    end
  end

  defp placeholders(value) when is_binary(value),
    do: @placeholder |> Regex.scan(value) |> Enum.map(fn [_full, ref] -> ref end)

  defp placeholders(value) when is_struct(value), do: []
  defp placeholders(value) when is_list(value), do: Enum.flat_map(value, &placeholders/1)

  defp placeholders(value) when is_map(value),
    do: Enum.flat_map(value, fn {_k, v} -> placeholders(v) end)

  defp placeholders(_value), do: []

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

  # Two dialects live side by side: a `Zoi.object` (a struct whose `fields` is a
  # keyword list of typed values carrying `meta.required`) and a NimbleOptions
  # keyword list (`[name: [required: true, ...]]`).
  defp schema_fields(%{fields: fields}) when is_list(fields),
    do: Enum.map(fields, fn {name, type} -> {to_string(name), type.meta.required == true} end)

  defp schema_fields(schema) when is_list(schema),
    do:
      Enum.map(schema, fn {name, opts} ->
        {to_string(name), Keyword.get(opts, :required) == true}
      end)

  defp schema_fields(_schema), do: []

  # -- normalisation ------------------------------------------------------------

  # Nodes and edges reach here as structs (built from a changeset) or as
  # string-keyed maps (reloaded from JSONB). Both are normalised to string keys so
  # nothing downstream has to try an atom and then a string.
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

  # An edge condition is `%{"field" => ref, "op" => ..., ...}`. Only `field` is a
  # reference; `value` is the literal it is compared against, never a lookup.
  defp condition(%{} = condition) do
    case stringify(condition) do
      %{"field" => field} when is_binary(field) -> %{"field" => field}
      _ -> nil
    end
  end

  defp condition(_condition), do: nil

  # A mapping is `%{target_key => source_ref}`. Both sides are stringified: the
  # target names a field, the source is a dotted reference, and neither is useful
  # as an atom.
  defp mapping(mapping) when is_map(mapping),
    do: Map.new(mapping, fn {target, source} -> {to_string(target), to_string(source)} end)

  defp mapping(_mapping), do: %{}

  defp stringify(%{__struct__: _} = value), do: value

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {to_string(k), stringify(v)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value), do: value
end
