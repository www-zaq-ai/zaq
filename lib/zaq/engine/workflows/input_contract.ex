defmodule Zaq.Engine.Workflows.InputContract do
  @moduledoc """
  Derives what a workflow's trigger payload must contain.

      missing = all_inputs − fed_by_steps

  `start` is not a step, so an input fed from the `start` namespace is never in
  `fed_by_steps` and always survives the difference. That is the "except start"
  clause — it falls out of the definition rather than being special-cased.

  Every element of both sets is a `"node.field"` string, so two nodes needing a
  field of the same name stay distinct and the sets are directly comparable.
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
  def all_inputs(workflow), do: workflow |> needs() |> MapSet.new(&qualify/1)

  @doc """
  The inputs fed by the output of a previous step, as `"node.field"`.

  A field is fed when **every** source that writes into it names another node.
  A `start.*` source is the trigger payload, not a step output, so a field with
  even one `start` source is not fed and survives the difference — that is the
  "except start" clause.
  """
  @spec fed_by_steps(Workflow.t() | map()) :: MapSet.t(String.t())
  def fed_by_steps(workflow) do
    workflow
    |> needs()
    |> Enum.group_by(&qualify/1)
    |> Enum.filter(fn {_field, needs} -> Enum.all?(needs, &(&1.kind == :step)) end)
    |> MapSet.new(fn {field, _needs} -> field end)
  end

  @doc "`all_inputs/1` minus `fed_by_steps/1` — the inputs no previous step feeds."
  @spec missing(Workflow.t() | map()) :: MapSet.t(String.t())
  def missing(workflow),
    do: MapSet.difference(all_inputs(workflow), fed_by_steps(workflow))

  @doc """
  The paths the trigger payload must carry, as dotted strings.

  This is `missing/1` translated from `"node.field"` into what a caller can
  actually send: the `start.*` sources behind each unfed field, with the `start.`
  prefix stripped and duplicates collapsed.
  """
  @spec required_inputs(Workflow.t() | map()) :: [String.t()]
  def required_inputs(workflow) do
    unfed = missing(workflow)

    workflow
    |> needs()
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
  def required_input_shape(workflow) do
    workflow
    |> required_inputs()
    |> Enum.reduce(%{}, &put_path(&2, String.split(&1, ".")))
  end

  # A leaf never overwrites a branch already placed at the same key, and a branch
  # always replaces a leaf — so the deeper path wins whichever order they arrive.
  defp put_path(shape, [leaf]), do: Map.put_new(shape, leaf, nil)

  defp put_path(shape, [segment | rest]) do
    nested = if is_map(shape[segment]), do: shape[segment], else: %{}
    Map.put(shape, segment, put_path(nested, rest))
  end

  @doc """
  Inputs whose provenance the graph does not state.

  A mid-DAG node reads its predecessor's output at the fact root, so a required
  field with no mapping, no param reference, and no pinned default cannot be
  traced statically. Reported rather than folded into `missing/1`, which would
  claim the payload must supply something it may not.
  """
  @spec unknown_inputs(Workflow.t() | map()) :: [String.t()]
  def unknown_inputs(workflow) do
    workflow
    |> needs()
    |> Enum.filter(&(&1.kind == :unknown))
    |> Enum.map(&qualify/1)
    |> Enum.uniq()
    |> Enum.sort()
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

    Enum.flat_map(nodes, &node_needs(&1, edges, names)) ++
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
        kind: condition_kind(field)
      }
    ]
  end

  defp condition_needs(_edge), do: []

  # `EdgeStep` resolves the condition field through `FactLookup` against the fact
  # flowing along the edge, so anything not rooted in `start` reads that fact —
  # the source node's own output, or a step named in the cascade. Unlike `need/5`,
  # a bare root here is never untraceable: the step the edge leaves feeds it.
  defp condition_kind(field) do
    case String.split(field, ".") do
      [@start | [_ | _]] -> :start
      _ -> :step
    end
  end

  defp node_needs(node, edges, names) do
    name = node["name"]
    incoming = Enum.filter(edges, &(&1["to"] == name))

    mapped = incoming |> Enum.flat_map(&Map.keys(&1["mapping"])) |> MapSet.new()
    pinned = node["params"] |> Map.keys() |> MapSet.new()
    local = MapSet.union(mapped, pinned)

    edge_needs(incoming, name, names, local) ++
      param_needs(node, name, names, local) ++
      schema_needs(node, name, incoming, local)
  end

  defp edge_needs(incoming, name, names, local) do
    incoming
    |> Enum.flat_map(&Map.to_list(&1["mapping"]))
    |> Enum.map(fn {target, source} -> need(name, target, source, names, local) end)
  end

  defp param_needs(node, name, names, local) do
    Enum.map(param_references(node), fn {field, source} ->
      need(name, field, source, names, local)
    end)
  end

  # Only fields nothing else writes fall through to the schema. An entry node
  # reads the trigger payload flat at the fact root, so its unwritten required
  # fields come from `start`; a mid-DAG node's provenance is untraceable.
  #
  # `start` is not a step, so an edge leaving it does not make the target mid-DAG:
  # a node fed only from `start` is still an entry node.
  defp schema_needs(node, name, incoming, local) do
    entry? = Enum.all?(incoming, &(&1["from"] == @start))

    node["module"]
    |> required_schema_fields()
    |> Enum.reject(&MapSet.member?(local, &1))
    |> Enum.map(fn field ->
      if entry?,
        do: %{node: name, field: field, source: qualified_start(field), kind: :start},
        else: %{node: name, field: field, source: nil, kind: :unknown}
    end)
  end

  # Classifies where a source reads from. A leading `start` is the trigger
  # payload; a leading node name is that step's output; a bare or otherwise-rooted
  # reference is a key of this node's own fact, satisfied when something local
  # writes it and untraceable otherwise.
  defp need(node, field, source, names, local) do
    kind =
      case String.split(source, ".") do
        [@start | [_ | _]] ->
          :start

        [root | [_ | _]] ->
          if MapSet.member?(names, root), do: :step, else: local_kind(root, local)

        [root] ->
          local_kind(root, local)
      end

    %{node: node, field: field, source: source, kind: kind}
  end

  # A local reference is fed by whatever writes that key on this node — which is
  # itself a need, already counted. Treating it as `:step` keeps it from being
  # double-reported as something the payload must supply.
  defp local_kind(root, local), do: if(MapSet.member?(local, root), do: :step, else: :unknown)

  defp qualify(%{node: node, field: field}), do: "#{node}.#{field}"
  defp qualified_start(field), do: "#{@start}.#{field}"

  # -- param references ---------------------------------------------------------

  # Same placeholder class as `Concat` and `DispatchEvent`.
  @placeholder ~r/\{\{\s*([\w.][\w.\s-]*?)\s*\}\}/

  # Params of these modules are read for references; every other action receives
  # its params literally (`StepRunner` resolves edge mappings, never node params),
  # so a dotted string elsewhere is data, not a reference.
  @placeholder_sites %{
    "Zaq.Agent.Tools.Workflow.Concat" => ["parts"],
    "Zaq.Agent.Tools.Workflow.DispatchEvent" => ["input"],
    "Zaq.Agent.Tools.Workflow.RunAgent" => ["input", "context"],
    "Zaq.Agent.Tools.Workflow.Condition" => ["input", "conditions"]
  }

  @condition_module "Zaq.Agent.Tools.Workflow.Condition"

  # Returns `{field, source}` pairs, where `field` is the param the reference sits
  # in — several references may share one field, and the field is unfed unless all
  # of them are step-sourced.
  defp param_references(%{"module" => module, "params" => params}) do
    sites = Map.get(@placeholder_sites, module, [])

    placeholders =
      Enum.flat_map(sites, fn field ->
        params |> Map.get(field) |> placeholders() |> Enum.map(&{field, &1})
      end)

    placeholders ++ bare_references(module, params)
  end

  # `Condition` resolves a bare dotted `input` against the cascade, and evaluates
  # each `conditions[].key` against a map carrying `__cascade__` — both are
  # references without any `{{}}`.
  defp bare_references(@condition_module, params) do
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

    input ++ keys
  end

  defp bare_references(_module, _params), do: []

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
