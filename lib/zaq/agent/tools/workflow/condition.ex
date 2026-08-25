defmodule Zaq.Agent.Tools.Workflow.Condition do
  @moduledoc """
  Checks that all specified key/value conditions hold on an input map.

  The behaviour on success and failure depends on `on_fail`:

  - `:halt` (default) — the **linear-guard** mode. All conditions pass →
    `{:ok, %{passed: true, input: input}}` (the input is passed through so the next
    step in the chain can read it). One or more fail → `{:error, reason}` where
    `reason` is a human-readable sentence naming each failed field, its expected
    value, and the actual value — e.g.
    `Condition not met: position must equal "CFO" but was "CTO"` — which stops the
    workflow step and is shown verbatim in the run view.
  - `:continue` — the **routing** mode (if/else branching). Returns
    `{:ok, %{passed: true}}` or `{:ok, %{passed: false, failed_conditions: [...]}}` so
    downstream **edges** route on the `passed` flag (node evaluates, edge routes).
    `input` is deliberately **omitted** here: passing a generic `input` through would
    clobber a downstream node's own `input` param (the fact wins on a key collision —
    e.g. `RunAgent`'s prompt template). The evaluated data is still reachable via
    cascade (`<node>.input.*`) and the persistent `start.*` namespace.

  `on_fail` may be given as an atom (`:halt` / `:continue`) or, when authored in a
  persisted workflow, as the equivalent string (`"halt"` / `"continue"`).

  ## Condition format

  Each condition is a map with a `"key"` and `"value"` entry, plus an optional
  `"op"` (defaults to `"eq"`) and optional `"type"`:

      %{"key" => "active", "value" => true}
      %{"key" => "flagged", "value" => false}

  ## Date conditions

  Set `"type" => "date"` or `"type" => "datetime"` to compare `%Date{}` /
  `%DateTime{}` values chronologically (via `Zaq.Engine.Workflows.EdgeCondition`
  / `DateOperand`) instead of by term order. The `"value"` accepts an ISO8601
  string, a sentinel (`"today"` / `"now"`), or a relative map — so "last email
  older than 7 days" is:

      %{"key" => "last_sent_at", "type" => "datetime", "op" => "lt",
        "value" => %{"from" => "now", "days" => -7}}

  A `"key"` is a **selector into `input`** — nothing else. A plain key names a
  top-level field and a dotted key descends nested maps
  (`"record.id"` reads `input["record"]["id"]`). It never reaches the run cascade,
  so a key means the same thing whatever the graph around it is named. Both atom and
  string forms resolve through `Zaq.Engine.Workflows.FactLookup`, so the tool works
  against in-memory and JSONB-rehydrated maps transparently.

  ## References

  Everything a condition reads has to be *in* `input`. Bring an upstream result in
  through `input` — `"{{build_history.metadata}}"`, which
  `Zaq.Engine.Workflows.StepRunner` resolves to the map before `run/2` — or through
  the edge mapping that feeds this node, then address it locally. A bare string is
  data, not a reference.

  ## Example

      input:      %{active: true, flagged: false, name: "John"}
      conditions: [%{"key" => "active", "value" => true},
                   %{"key" => "flagged", "value" => false}]
      → %{passed: true, input: %{active: true, flagged: false, name: "John"}}
  """

  use Zaq.Engine.Workflows.Action,
    name: "condition",
    description: "Checks that all key/value conditions hold on an input map.",
    schema: [
      input: [
        type: {:or, [:map, :string]},
        required: true,
        doc:
          "Map to evaluate conditions against. Normally delivered by the upstream node " <>
            "or by Batch/Iterate (this is the batch delivery field). To evaluate an " <>
            "upstream result instead, write a placeholder — `\"{{build_history.metadata}}\"` " <>
            "— which `StepRunner` resolves to the map before this action runs. When absent " <>
            "— e.g. a Condition that is the first node off a trigger — `run/2` falls back " <>
            "to the incoming fact at root; `start.<field>` dotted keys reach the trigger " <>
            "payload."
      ],
      conditions: [
        type: {:list, :map},
        required: false,
        default: [],
        doc:
          ~s|List of conditions. Each must have "key" (a selector into `input`; dotted keys descend nested maps) and "value"; optional "op" defaults to "eq". Supported ops: eq, neq, gt, lt, gte, lte, not_empty, empty, in. Optional "type" ("date"/"datetime") compares chronologically; "value" then accepts an ISO8601 string, "today"/"now", or a relative map like %{"from" => "now", "days" => -7}.|
      ],
      on_fail: [
        type: {:in, [:halt, :continue]},
        required: false,
        default: :halt,
        doc:
          ":halt returns an error (stops the workflow); :continue returns ok with passed: false."
      ]
    ],
    output_schema: [
      passed: [type: :boolean, required: true, doc: "true if all conditions matched."],
      input: [
        type: :map,
        required: false,
        doc:
          "The original input map, passed through — present only in :halt mode. In :continue " <>
            "(routing) mode it is omitted so it cannot clobber a downstream node's own `input` " <>
            "param; the data stays reachable via cascade (`<node>.input.*`)."
      ],
      failed_conditions: [
        type: {:list, :any},
        required: false,
        doc: "Conditions that did not match. Present only when passed: false (continue mode)."
      ]
    ]

  alias Zaq.Engine.Workflows.EdgeCondition
  alias Zaq.Engine.Workflows.FactLookup

  require Logger

  @impl Jido.Action
  def run(params, context) do
    conditions = Map.get(params, :conditions, [])
    on_fail = normalize_on_fail(Map.get(params, :on_fail))
    input = resolve_input(params)

    failed = Enum.reject(conditions, &condition_passes?(&1, input))

    Logger.debug("[condition] evaluated",
      run_id: Map.get(context, :run_id),
      step_name: Map.get(context, :step_name),
      failed: length(failed)
    )

    cond do
      # Routing mode (`:continue`) emits ONLY the routing signal. Passing a generic
      # `input` through would clobber a downstream node's own `input` param (e.g.
      # RunAgent's prompt template), since the fact wins on a key collision. The
      # evaluated data stays reachable downstream via cascade (`<node>.input.*`) and
      # the persistent `start.*` namespace — node evaluates, edges route.
      on_fail == :continue ->
        {:ok, routing_result(failed)}

      failed == [] ->
        {:ok, %{passed: true, input: input}}

      true ->
        {:error,
         "Condition not met: " <> Enum.map_join(failed, "; ", &describe_failure(&1, input))}
    end
  end

  defp routing_result([]), do: %{passed: true}
  defp routing_result(failed), do: %{passed: false, failed_conditions: failed}

  # Builds one human-readable clause per failed condition, e.g.
  # `position must equal "CFO" but was "CTO"`. Names the field, what was expected,
  # and the actual value, so the run-view error is self-explanatory.
  defp describe_failure(condition, input) do
    field = get_field(condition, "key") || "field"
    op = (get_field(condition, "op") || "eq") |> to_op()
    type = get_field(condition, "type")
    expected = get_field(condition, "value")
    actual = actual_value(condition, input)

    if type in ["date", "datetime"] and op not in [:empty, :not_empty] do
      "#{field} #{date_op_phrase(op)} #{render(expected)} but was #{render(actual)}"
    else
      phrase(field, op, expected, actual)
    end
  end

  defp actual_value(condition, input) do
    case FactLookup.fetch(input, get_field(condition, "key")) do
      {:ok, value} -> value
      :error -> get_field(condition, "default")
    end
  end

  defp phrase(field, :not_empty, _expected, _actual), do: "#{field} must not be empty"

  defp phrase(field, :empty, _expected, actual),
    do: "#{field} must be empty but was #{render(actual)}"

  defp phrase(field, op, expected, actual),
    do: "#{field} #{op_phrase(op)} #{render(expected)} but was #{render(actual)}"

  defp op_phrase(:eq), do: "must equal"
  defp op_phrase(:neq), do: "must not equal"
  defp op_phrase(:gt), do: "must be greater than"
  defp op_phrase(:lt), do: "must be less than"
  defp op_phrase(:gte), do: "must be at least"
  defp op_phrase(:lte), do: "must be at most"
  defp op_phrase(:in), do: "must be one of"
  defp op_phrase(op), do: "must satisfy #{op}"

  # Date/datetime conditions read more naturally as before/after than gt/lt.
  defp date_op_phrase(:eq), do: "must be"
  defp date_op_phrase(:neq), do: "must not be"
  defp date_op_phrase(:gt), do: "must be after"
  defp date_op_phrase(:lt), do: "must be before"
  defp date_op_phrase(:gte), do: "must be on or after"
  defp date_op_phrase(:lte), do: "must be on or before"
  defp date_op_phrase(op), do: op_phrase(op)

  defp render(nil), do: "empty"
  defp render(value), do: inspect(value)

  # The map to evaluate conditions against:
  #   - an explicit `:input`, used as-is. A reference is written `{{a.b}}` and is
  #     already resolved to its value by `StepRunner`, so whatever arrives here is
  #     data — a string `input` is a string, never a reference;
  #   - absent → the incoming fact at root (first node off a trigger), minus this
  #     action's own config keys.
  # The persistent `start` namespace rides along via the cascade in every case and is
  # reachable through `start.<field>` dotted keys.
  defp resolve_input(params) do
    case Map.fetch(params, :input) do
      {:ok, input} -> input
      :error -> Map.drop(params, [:conditions, :on_fail])
    end
  end

  # `on_fail` arrives as an atom (direct calls / tests) or a string (authored in
  # JSONB — `DagBuilder.atomize_keys` atomizes keys but leaves values as strings).
  # Accept both; default to `:halt` when absent or unrecognized.
  defp normalize_on_fail(value) when value in [:continue, "continue"], do: :continue
  defp normalize_on_fail(_value), do: :halt

  defp condition_passes?(condition, input) do
    key = get_field(condition, "key")
    value = get_field(condition, "value")
    op = (get_field(condition, "op") || "eq") |> to_op()
    opts = [type: get_field(condition, "type")]

    case FactLookup.fetch(input, key) do
      {:ok, actual} ->
        EdgeCondition.evaluate(op, actual, value, opts)

      :error ->
        default = get_field(condition, "default")
        not is_nil(default) and EdgeCondition.evaluate(op, default, value, opts)
    end
  end

  defp get_field(map, string_key) do
    case Map.fetch(map, string_key) do
      {:ok, v} -> v
      :error -> Map.get(map, String.to_existing_atom(string_key))
    end
  rescue
    ArgumentError -> nil
  end

  defp to_op(op) when is_atom(op), do: op
  defp to_op(op) when is_binary(op), do: String.to_existing_atom(op)
end
